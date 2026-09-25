#include "fluxbackend.h"

#include <QDir>
#include <QJSEngine>
#include <QProcess>
#include <QStandardPaths>

namespace {
// retryInterval is the time between connection attempts while fluxd is
// not running.
constexpr int retryInterval = 2000;
// firstAttemptGrace is the time after start at which the window may show
// "fluxd is not running", also when the first attempt has not finished.
constexpr int firstAttemptGrace = 800;
}

FluxBackend::FluxBackend(QJSEngine *engine, QObject *parent)
    : QObject(parent), m_engine(engine), m_state(engine->newObject())
{
    m_retry.setInterval(retryInterval);
    connect(&m_retry, &QTimer::timeout, this, &FluxBackend::connectNow);

    connect(&m_socket, &QLocalSocket::connected, this, [this] {
        m_retry.stop();
        setAttempted();
        emit connectedChanged();
        call(QStringLiteral("subscribe"));
    });
    connect(&m_socket, &QLocalSocket::disconnected, this, [this] {
        failPending(QStringLiteral("offline"), QStringLiteral("fluxd is not running"));
        emit connectedChanged();
        m_retry.start();
    });
    connect(&m_socket, &QLocalSocket::errorOccurred, this, [this](QLocalSocket::LocalSocketError) {
        setAttempted();
        if (m_socket.state() != QLocalSocket::ConnectedState)
            m_retry.start();
    });
    connect(&m_socket, &QLocalSocket::readyRead, this, [this] {
        while (m_socket.canReadLine())
            handleLine(m_socket.readLine().trimmed());
    });

    QTimer::singleShot(firstAttemptGrace, this, &FluxBackend::setAttempted);
    connectNow();
}

QString FluxBackend::socketPath()
{
    const QString override = qEnvironmentVariable("FLUX_SOCKET");
    if (!override.isEmpty())
        return override;
    QString runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
    if (runtime.isEmpty())
        runtime = QDir::tempPath();
    return runtime + QStringLiteral("/flux/fluxd.sock");
}

void FluxBackend::connectNow()
{
    if (m_socket.state() != QLocalSocket::UnconnectedState)
        return;
    m_socket.connectToServer(socketPath());
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
            const auto lines = QString::fromUtf8(proc->readAllStandardOutput()).split(u'\n');
            for (const QString &line : lines) {
                const QString path = line.trimmed();
                if (!path.isEmpty())
                    paths.setProperty(i++, path);
            }
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
            connectNow();
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
    // The button turns fluxd on, so it removes the marker of `flux off` first.
    proc->start(QStringLiteral("sh"),
                {QStringLiteral("-c"),
                 QStringLiteral("rm -f \"${XDG_CONFIG_HOME:-$HOME/.config}/flux/off\"; systemctl --user start fluxd")});
}
