#include "singleinstance.h"

#include "fluxbackend.h"

#include <QElapsedTimer>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalSocket>
#include <QThread>

#include <cerrno>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {
constexpr int connectTimeout = 300;
constexpr int writeTimeout = 1000;
// claimTimeout limits the wait for an instance that holds the lock but
// does not answer, for example while it starts or quits.
constexpr int claimTimeout = 5000;
constexpr int claimRetry = 100;

// privateDir makes the folder when it is missing. It returns true when the
// folder belongs to this user. An earlier flux-gui made the folder with the
// umask, so the mode of a folder of this user changes to 0700.
bool privateDir(const QString &path)
{
    const QByteArray dir = QFile::encodeName(path);
    if (::mkdir(dir.constData(), 0700) != 0 && errno != EEXIST)
        return false;
    struct stat st;
    if (::lstat(dir.constData(), &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != ::getuid())
        return false;
    return (st.st_mode & 077) == 0 || ::chmod(dir.constData(), 0700) == 0;
}
}

SingleInstance::SingleInstance(QObject *parent) : QObject(parent)
{
    connect(&m_server, &QLocalServer::newConnection, this, [this] {
        while (QLocalSocket *client = m_server.nextPendingConnection()) {
            connect(client, &QLocalSocket::disconnected, client, &QObject::deleteLater);
            connect(client, &QLocalSocket::readyRead, this, [this, client] {
                if (!client->canReadLine())
                    return;
                const QJsonObject req = QJsonDocument::fromJson(client->readLine()).object();
                emit activate(req.value(QLatin1String("page")).toString(), req.value(QLatin1String("token")).toString());
                client->disconnectFromServer();
            });
        }
    });
}

SingleInstance::~SingleInstance()
{
    close();
}

QString SingleInstance::socketPath()
{
    return FluxBackend::runtimeDir() + QStringLiteral("/gui.sock");
}

bool SingleInstance::forward(const QString &page)
{
    QLocalSocket socket;
    socket.connectToServer(socketPath());
    if (!socket.waitForConnected(connectTimeout))
        return false;
    const QJsonObject req{
        {QLatin1String("page"), page},
        {QLatin1String("token"), qEnvironmentVariable("XDG_ACTIVATION_TOKEN")},
    };
    socket.write(QJsonDocument(req).toJson(QJsonDocument::Compact) + '\n');
    return socket.waitForBytesWritten(writeTimeout);
}

bool SingleInstance::openLock()
{
    const QString dir = FluxBackend::runtimeDir();
    if (!privateDir(dir)) {
        qWarning("flux-gui: %s is missing, or it belongs to another user", qPrintable(dir));
        return false;
    }
    // O_CLOEXEC keeps the lock out of the programs that flux-gui starts,
    // such as its new version after an update.
    const QByteArray path = QFile::encodeName(dir + QStringLiteral("/gui.lock"));
    m_lock = ::open(path.constData(), O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (m_lock < 0) {
        qWarning("flux-gui: cannot open %s", path.constData());
        return false;
    }
    return true;
}

bool SingleInstance::claim(const QString &page, bool replace)
{
    // Without the lock, the window opens with no single-instance server.
    if (!openLock())
        return true;
    QElapsedTimer waited;
    waited.start();
    for (;;) {
        if (::flock(m_lock, LOCK_EX | LOCK_NB) == 0) {
            // A flux-gui from before the lock listens without it, for
            // example after an update and before its restart. Send the
            // request to that instance, and do not remove its socket.
            if (!replace && forward(page)) {
                close();
                return false;
            }
            // Only the holder of the lock listens, so a socket file that is
            // there now is from an instance that stopped.
            const QString path = socketPath();
            QLocalServer::removeServer(path);
            m_server.setSocketOptions(QLocalServer::UserAccessOption);
            if (!m_server.listen(path))
                qWarning("flux-gui: cannot listen on %s", qPrintable(path));
            return true;
        }
        // Another instance holds the lock. It can still be before its
        // listen, so try again for a short time.
        if (!replace && forward(page))
            return false;
        if (waited.elapsed() > claimTimeout) {
            qWarning("flux-gui: another flux-gui holds the lock and does not answer");
            close();
            return true;
        }
        QThread::msleep(claimRetry);
    }
}

void SingleInstance::close()
{
    m_server.close();
    if (m_lock >= 0) {
        ::close(m_lock);
        m_lock = -1;
    }
}
