#include "singleinstance.h"

#include <QDir>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalSocket>

namespace {
constexpr int connectTimeout = 300;
constexpr int writeTimeout = 1000;
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

QString SingleInstance::socketPath()
{
    QString runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
    if (runtime.isEmpty())
        runtime = QDir::tempPath();
    return runtime + QStringLiteral("/flux/gui.sock");
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

bool SingleInstance::listen()
{
    const QString path = socketPath();
    QDir().mkpath(QFileInfo(path).absolutePath());
    m_server.setSocketOptions(QLocalServer::UserAccessOption);
    if (m_server.listen(path))
        return true;
    // A crashed instance leaves the socket file. No instance answered, so
    // remove it and listen again.
    QLocalServer::removeServer(path);
    return m_server.listen(path);
}
