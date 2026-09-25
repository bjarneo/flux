#pragma once

#include <QColor>
#include <QFileSystemWatcher>
#include <QObject>
#include <QTimer>

// ThemeWatcher reads the colors.toml of the active Omarchy theme and reads
// it again when it changes. A theme switch replaces the files, so the
// watcher also looks at the parent folders and compares the content every
// 2 seconds.
class ThemeWatcher : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString text READ text NOTIFY textChanged)
    Q_PROPERTY(QColor background READ background NOTIFY textChanged)

public:
    explicit ThemeWatcher(QObject *parent = nullptr);

    QString text() const { return m_text; }
    // background is the window color before the views load.
    QColor background() const { return m_background; }

    static QString themePath();

signals:
    void textChanged();

private:
    void reload();
    void watch();

    QString m_path;
    QString m_text;
    QColor m_background;
    QFileSystemWatcher m_watcher;
    QTimer m_poll;
};
