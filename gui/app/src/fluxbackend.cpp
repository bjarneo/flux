#include "fluxbackend.h"

#include <QJSEngine>
#include <QProcess>

#include <sys/socket.h>
#include <unistd.h>

namespace {
// minRetryDelay and maxRetryDelay limit the wait between connection
// attempts while fluxd is not running. The wait doubles after each failed
// attempt.
constexpr int minRetryDelay = 2000;
constexpr int maxRetryDelay = 60000;
// firstAttemptGrace is the time after start at which the window may show
// "fluxd is not running", also when the first attempt has not finished.
constexpr int firstAttemptGrace = 800;
// maxLine is the largest line from fluxd that the backend reads. Normal
// state events are much smaller. A longer line is dropped, and the
// connection stays open.
constexpr qint64 maxLine = 32 * 1024 * 1024;

// peerIsUser reports whether the process at the other end of socket runs
// as the same user as this process.
bool peerIsUser(qintptr socket)
{
    struct ucred cred {};
    socklen_t len = sizeof(cred);
    if (::getsockopt(int(socket), SOL_SOCKET, SO_PEERCRED, &cred, &len) != 0)
        return false;
    return cred.uid == ::getuid();
}
}

QStringList FluxBackend::chooserPaths(QString text)
{
    if (text.endsWith(u'\n'))
        text.chop(1);
    QStringList paths;
    if (text.isEmpty())
        return paths;
    for (const QString &line : text.split(u'\n')) {
        if (line.startsWith(u'/') || paths.isEmpty())
            paths.append(line);
        else
            paths.last() += u'\n' + line;
    }
    paths.removeIf([](const QString &path) { return !path.startsWith(u'/'); });
    return paths;
}

FluxBackend::FluxBackend(QJSEngine *engine, QObject *parent)
    : QObject(parent), m_engine(engine), m_retryDelay(minRetryDelay), m_state(engine->newObject())
{
    m_retry.setSingleShot(true);
    connect(&m_retry, &QTimer::timeout, this, &FluxBackend::connectNow);

    connect(&m_socket, &QLocalSocket::connected, this, [this] {
        // Only a fluxd of this user gets the requests, which can hold
        // message text and command lines.
        if (!peerIsUser(m_socket.socketDescriptor())) {
            qWarning("flux-gui: %s belongs to another user", qPrintable(socketPath()));
            m_socket.abort();
            return;
        }
        m_retry.stop();
        m_retryDelay = minRetryDelay;
        setAttempted();
        emit connectedChanged();
        call(QStringLiteral("subscribe"));
    });
    connect(&m_socket, &QLocalSocket::disconnected, this, [this] {
        m_dropLine = false;
        failPending(QStringLiteral("offline"), QStringLiteral("fluxd is not running"));
        emit connectedChanged();
        scheduleRetry();
    });
    connect(&m_socket, &QLocalSocket::errorOccurred, this, [this](QLocalSocket::LocalSocketError) {
        setAttempted();
        if (m_socket.state() != QLocalSocket::ConnectedState)
            scheduleRetry();
    });
    connect(&m_socket, &QLocalSocket::readyRead, this, &FluxBackend::readLines);

    QTimer::singleShot(firstAttemptGrace, this, &FluxBackend::setAttempted);
    connectNow();
}

FluxBackend::~FluxBackend()
{
    // ~QLocalSocket closes the connection and emits disconnected. At that
    // time m_pending is already destroyed, and the engine that owns this
    // object is mid-destruction. Remove the socket handlers first.
    m_socket.disconnect(this);
}

QString FluxBackend::runtimeDir()
{
    QString runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
    if (runtime.isEmpty())
        runtime = QStringLiteral("/run/user/%1").arg(::getuid());
    return runtime + QStringLiteral("/flux");
}

QString FluxBackend::socketPath()
{
    const QString override = qEnvironmentVariable("FLUX_SOCKET");
    if (!override.isEmpty())
        return override;
    return runtimeDir() + QStringLiteral("/fluxd.sock");
}

void FluxBackend::connectNow()
{
    if (m_socket.state() != QLocalSocket::UnconnectedState)
        return;
    m_socket.connectToServer(socketPath());
}

// scheduleRetry starts the wait for the next attempt and doubles the wait
// for the attempt after it. A lost connection can report 2 signals, so a
// running wait stays as it is.
void FluxBackend::scheduleRetry()
{
    if (m_retry.isActive())
        return;
    m_retry.start(m_retryDelay);
    m_retryDelay = qMin(m_retryDelay * 2, maxRetryDelay);
}

void FluxBackend::retryNow()
{
    m_retry.stop();
    m_retryDelay = minRetryDelay;
    connectNow();
}

void FluxBackend::setAttempted()
{
    if (m_attempted)
        return;
    m_attempted = true;
    emit attemptedChanged();
}

void FluxBackend::call(const QString &method, const QJSValue &params, const QJSValue &cb)
{
    if (!connected()) {
        if (cb.isCallable())
            invoke(cb, {error(QStringLiteral("offline"), QStringLiteral("fluxd is not running")), QJSValue::NullValue});
        else
            emit toast(QStringLiteral("fluxd is not running"));
        return;
    }
    const int id = m_nextId++;
    if (cb.isCallable())
        m_pending.insert(id, cb);

    QJSValue request = m_engine->newObject();
    request.setProperty(QStringLiteral("id"), id);
    request.setProperty(QStringLiteral("method"), method);
    request.setProperty(QStringLiteral("params"), params.isObject() ? params : m_engine->newObject());
    const QJSValue stringify = m_engine->globalObject().property(QStringLiteral("JSON")).property(QStringLiteral("stringify"));
    const QString line = stringify.call({request}).toString();
    m_socket.write(line.toUtf8() + '\n');
    m_socket.flush();
}

// readLines reads each complete line. When a line without its end is above
// maxLine, the backend skips its bytes and drops the rest of the line. So
// the buffer never holds much more than maxLine.
void FluxBackend::readLines()
{
    while (m_socket.canReadLine()) {
        const QByteArray line = m_socket.readLine();
        if (m_dropLine) {
            m_dropLine = false;
            continue;
        }
        if (line.size() > maxLine) {
            qWarning("flux-gui: dropped a line from fluxd above %lld bytes", maxLine);
            continue;
        }
        handleLine(line.trimmed());
    }
    if (m_socket.bytesAvailable() > maxLine) {
        if (!m_dropLine)
            qWarning("flux-gui: dropped a line from fluxd above %lld bytes", maxLine);
        m_dropLine = true;
        m_socket.skip(m_socket.bytesAvailable());
    }
}

void FluxBackend::handleLine(const QByteArray &line)
{
    if (line.isEmpty())
        return;
    const QJSValue parse = m_engine->globalObject().property(QStringLiteral("JSON")).property(QStringLiteral("parse"));
    const QJSValue msg = parse.call({QString::fromUtf8(line)});
    if (msg.isError() || !msg.isObject())
        return;

    const QString event = msg.property(QStringLiteral("event")).toString();
    if (event == QLatin1String("state")) {
        const QJSValue data = msg.property(QStringLiteral("data"));
        m_state = data.isObject() ? data : m_engine->newObject();
        emit stateChanged();
        return;
    }
    if (event == QLatin1String("toast")) {
        const QString text = msg.property(QStringLiteral("data")).property(QStringLiteral("text")).toString();
        if (!text.isEmpty())
            emit toast(text);
        return;
    }

    const QJSValue idValue = msg.property(QStringLiteral("id"));
    if (!idValue.isNumber())
        return;
    const QJSValue cb = m_pending.take(idValue.toInt());
    const QJSValue err = msg.property(QStringLiteral("error"));
    if (err.isObject()) {
        if (cb.isCallable()) {
            invoke(cb, {err, QJSValue::NullValue});
        } else {
            QString text = err.property(QStringLiteral("message")).toString();
            if (text.isEmpty())
                text = err.property(QStringLiteral("code")).toString();
            emit toast(text.isEmpty() ? QStringLiteral("Error") : text);
        }
    } else if (cb.isCallable()) {
        QJSValue result = msg.property(QStringLiteral("result"));
        if (!result.isObject())
            result = m_engine->newObject();
        invoke(cb, {QJSValue::NullValue, result});
    }
}

void FluxBackend::failPending(const QString &code, const QString &message)
{
    const auto pending = std::exchange(m_pending, {});
    for (const QJSValue &cb : pending)
        invoke(cb, {error(code, message), QJSValue::NullValue});
}

void FluxBackend::invoke(QJSValue cb, const QJSValueList &args)
{
    const QJSValue result = cb.call(args);
    if (result.isError())
        qWarning("flux-gui: callback error: %s", qPrintable(result.toString()));
}

QJSValue FluxBackend::error(const QString &code, const QString &message) const
{
    QJSValue err = m_engine->newObject();
    err.setProperty(QStringLiteral("code"), code);
    err.setProperty(QStringLiteral("message"), message);
    return err;
}

QJSValue FluxBackend::field(const char *name, bool list) const
{
    const QJSValue value = m_state.property(QString::fromLatin1(name));
    if (list ? value.isArray() : value.isObject())
        return value;
    return list ? m_engine->newArray() : m_engine->newObject();
}

void FluxBackend::pickFiles(const QString &title, const QJSValue &cb)
{
    auto *proc = new QProcess(this);
    connect(proc, &QProcess::finished, this, [this, proc, cb](int code, QProcess::ExitStatus status) {
        proc->deleteLater();
        QJSValue paths = m_engine->newArray();
        if (status == QProcess::NormalExit && code == 0) {
            quint32 i = 0;
            for (const QString &path : chooserPaths(QString::fromUtf8(proc->readAllStandardOutput())))
                paths.setProperty(i++, path);
        } else {
            // Exit code 1 means that the user picked nothing. Other codes
            // mean that the chooser did not run.
            const QString message = QString::fromUtf8(proc->readAllStandardError()).trimmed();
            if (code != 1 && !message.isEmpty())
                emit toast(message.section(u'\n', 0, 0));
        }
        if (cb.isCallable())
            invoke(cb, {paths});
    });
    connect(proc, &QProcess::errorOccurred, this, [this, proc, cb](QProcess::ProcessError err) {
        if (err != QProcess::FailedToStart)
            return;
        proc->deleteLater();
        emit toast(QStringLiteral("The Omarchy file chooser is not available"));
        if (cb.isCallable())
            invoke(cb, {m_engine->newArray()});
    });
    proc->start(QStringLiteral("omarchy"),
                {QStringLiteral("file"), QStringLiteral("select"), QStringLiteral("--title"), title,
                 QStringLiteral("--multiple")});
}

void FluxBackend::startDaemon(const QJSValue &cb)
{
    auto *proc = new QProcess(this);
    connect(proc, &QProcess::finished, this, [this, proc, cb](int code, QProcess::ExitStatus status) {
        proc->deleteLater();
        const bool ok = status == QProcess::NormalExit && code == 0;
        const QString message = QString::fromUtf8(proc->readAllStandardError()).trimmed();
        if (ok)
            retryNow();
        if (cb.isCallable())
            invoke(cb, {ok, message});
    });
    connect(proc, &QProcess::errorOccurred, this, [this, proc, cb](QProcess::ProcessError err) {
        if (err != QProcess::FailedToStart)
            return;
        proc->deleteLater();
        if (cb.isCallable())
            invoke(cb, {false, QStringLiteral("systemctl is not available")});
    });
    // The button turns fluxd on, so it removes the marker of `flux-cli off` first.
    proc->start(QStringLiteral("sh"),
                {QStringLiteral("-c"),
                 QStringLiteral("rm -f \"${XDG_CONFIG_HOME:-$HOME/.config}/flux/off\"; systemctl --user start fluxd")});
}
