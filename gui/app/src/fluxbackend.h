#pragma once

#include <QHash>
#include <QJSValue>
#include <QLocalSocket>
#include <QObject>
#include <QTimer>

class QJSEngine;

// FluxBackend is the client of the fluxd IPC socket. Each message is one
// JSON object on one line. After subscribe, fluxd sends the full state
// after each change. The API is the same as the backend object that the
// shared QML views expect.
class FluxBackend : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool connected READ connected NOTIFY connectedChanged)
    Q_PROPERTY(bool attempted READ attempted NOTIFY attemptedChanged)
    Q_PROPERTY(QJSValue state READ state NOTIFY stateChanged)
    Q_PROPERTY(QJSValue devices READ devices NOTIFY stateChanged)
    Q_PROPERTY(QJSValue clipboard READ clipboard NOTIFY stateChanged)
    Q_PROPERTY(QJSValue transfers READ transfers NOTIFY stateChanged)
    Q_PROPERTY(QJSValue commands READ commands NOTIFY stateChanged)
    Q_PROPERTY(QJSValue settings READ settings NOTIFY stateChanged)
    Q_PROPERTY(QJSValue selfDevice READ selfDevice NOTIFY stateChanged)

public:
    explicit FluxBackend(QJSEngine *engine, QObject *parent = nullptr);
    ~FluxBackend() override;

    bool connected() const { return m_socket.state() == QLocalSocket::ConnectedState; }
    bool attempted() const { return m_attempted; }
    QJSValue state() const { return m_state; }
    QJSValue devices() const { return field("devices", true); }
    QJSValue clipboard() const { return field("clipboard", true); }
    QJSValue transfers() const { return field("transfers", true); }
    QJSValue commands() const { return field("commands", true); }
    QJSValue settings() const { return field("settings", false); }
    QJSValue selfDevice() const { return field("self", false); }

    // call sends a request. cb receives (err, result). err is
    // {code, message} or null. Without cb, an error becomes a toast.
    Q_INVOKABLE void call(const QString &method, const QJSValue &params = QJSValue(),
                          const QJSValue &cb = QJSValue());
    // pickFiles opens the Omarchy file chooser. cb receives an array of
    // absolute paths, which is empty when the user cancels.
    Q_INVOKABLE void pickFiles(const QString &title, const QJSValue &cb);
    // startDaemon starts the fluxd user service. cb receives (ok, message).
    Q_INVOKABLE void startDaemon(const QJSValue &cb);
    // retryNow connects at once when the connection is down, and starts
    // the wait between attempts again at the shortest time.
    Q_INVOKABLE void retryNow();

    // runtimeDir returns the folder of the Flux sockets: $XDG_RUNTIME_DIR/flux,
    // or /run/user/<uid>/flux. fluxd and flux-cli use the same folder. There
    // is no /tmp fallback, because another user can make a folder there first.
    static QString runtimeDir();
    // socketPath returns $FLUX_SOCKET, or fluxd.sock in runtimeDir.
    static QString socketPath();
    // chooserPaths reads the output of omarchy file select: 1 absolute path
    // on each line. A file name can have a newline, so a line that does not
    // start with "/" continues the path before it. The lines are not
    // trimmed, because a file name can start or end with a space.
    static QStringList chooserPaths(QString text);

signals:
    void connectedChanged();
    void attemptedChanged();
    void stateChanged();
    void toast(const QString &text);

private:
    void connectNow();
    void scheduleRetry();
    void setAttempted();
    void readLines();
    void handleLine(const QByteArray &line);
    void failPending(const QString &code, const QString &message);
    void invoke(QJSValue cb, const QJSValueList &args);
    QJSValue error(const QString &code, const QString &message) const;
    QJSValue field(const char *name, bool list) const;

    QJSEngine *m_engine;
    QLocalSocket m_socket;
    QTimer m_retry;
    int m_retryDelay;
    bool m_attempted = false;
    QJSValue m_state;
    int m_nextId = 1;
    QHash<int, QJSValue> m_pending;
    // m_dropLine is true while the backend drops the rest of a line above
    // the size limit.
    bool m_dropLine = false;
};
