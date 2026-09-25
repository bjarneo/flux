#include "themewatcher.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>

namespace {
constexpr int pollInterval = 2000;
// defaultBackground is the Tokyo Night background from the design.
const QColor defaultBackground(QStringLiteral("#1a1b26"));
}

ThemeWatcher::ThemeWatcher(QObject *parent)
    : QObject(parent), m_path(themePath()), m_background(defaultBackground)
{
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, &ThemeWatcher::reload);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, &ThemeWatcher::reload);
    m_poll.setInterval(pollInterval);
    connect(&m_poll, &QTimer::timeout, this, &ThemeWatcher::reload);
    m_poll.start();
    reload();
}

QString ThemeWatcher::themePath()
{
    const QString override = qEnvironmentVariable("FLUX_THEME_FILE");
    if (!override.isEmpty())
        return override;
    return QDir::homePath() + QStringLiteral("/.local/state/omarchy/current/theme/colors.toml");
}

void ThemeWatcher::watch()
{
    // A replaced file drops out of the watch list, so add the paths again.
    const QFileInfo info(m_path);
    const QStringList paths{m_path, info.absolutePath(), QFileInfo(info.absolutePath()).absolutePath()};
    for (const QString &p : paths) {
        if (QFileInfo::exists(p) && !m_watcher.files().contains(p) && !m_watcher.directories().contains(p))
            m_watcher.addPath(p);
    }
}

void ThemeWatcher::reload()
{
    watch();
    QFile file(m_path);
    QString text;
    if (file.open(QIODevice::ReadOnly))
        text = QString::fromUtf8(file.readAll());
    if (text == m_text)
        return;
    m_text = text;

    static const QRegularExpression bgLine(QStringLiteral(R"re(^\s*background\s*=\s*"(#[0-9a-fA-F]{6})")re"),
                                           QRegularExpression::MultilineOption);
    const auto match = bgLine.match(m_text);
    m_background = match.hasMatch() ? QColor(match.captured(1)) : defaultBackground;
    emit textChanged();
}
