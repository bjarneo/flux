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
    Q_PROPERTY(bool ringing READ ringing NOTIFY stateChanged)
    Q_PROPERTY(QJSValue selfDevice READ selfDevice NOTIFY stateChanged)

public:
    explicit FluxBackend(QJSEngine *engine, QObject *parent = nullptr);

    bool connected() const { return m_socket.state() == QLocalSocket::ConnectedState; }
    bool attempted() const { return m_attempted; }
    QJSValue state() const { return m_state; }
    QJSValue devices() const { return field("devices", true); }
    QJSValue clipboard() const { return field("clipboard", true); }
    QJSValue transfers() const { return field("transfers", true); }
    QJSValue commands() const { return field("commands", true); }
    QJSValue settings() const { return field("settings", false); }
    QJSValue selfDevice() const { return field("self", false); }
    bool ringing() const { return m_state.property("ringing").toBool(); }

    // call sends a request. cb receives (err, result). err is
    // {code, message} or null. Without cb, an error becomes a toast.
    Q_INVOKABLE void call(const QString &method, const QJSValue &params = QJSValue(),
                          const QJSValue &cb = QJSValue());
    // pickFiles opens the Omarchy file chooser. cb receives an array of
    // absolute paths, which is empty when the user cancels.
    Q_INVOKABLE void pickFiles(const QString &title, const QJSValue &cb);
    // startDaemon starts the fluxd user service. cb receives (ok, message).
    Q_INVOKABLE void startDaemon(const QJSValue &cb);

    static QString socketPath();

signals:
    void connectedChanged();
    void attemptedChanged();
    void stateChanged();
    void toast(const QString &text);

private:
    void connectNow();
    void setAttempted();
    void handleLine(const QByteArray &line);
    void failPending(const QString &code, const QString &message);
    void invoke(QJSValue cb, const QJSValueList &args);
    QJSValue error(const QString &code, const QString &message) const;
    QJSValue field(const char *name, bool list) const;

    QJSEngine *m_engine;
    QLocalSocket m_socket;
    QTimer m_retry;
    bool m_attempted = false;
    QJSValue m_state;
    int m_nextId = 1;
    QHash<int, QJSValue> m_pending;
};
