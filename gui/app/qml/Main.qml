import QtQuick

// The Flux window. It loads the shared views from fluxQmlBase, so the
// same views run from the resources or, with FLUX_QML_DIR, from disk.
Window {
  id: root
  title: "Flux"
  width: 1180
  height: 760
  minimumWidth: 900
  minimumHeight: 640
  visible: true
  color: fluxTheme.background

  // showPage selects a screen by its key, for example "files".
  function showPage(page) {
    if (view.item && page) view.item.showPage(String(page))
  }

  Loader {
    id: view
    anchors.fill: parent
    focus: true

    Component.onCompleted: setSource(fluxQmlBase + "/FluxView.qml", {
      backend: fluxBackend,
      themeText: fluxTheme.text
    })

    onLoaded: {
      item.themeText = Qt.binding(function () { return fluxTheme.text })
      item.forceActiveFocus()
      if (fluxInitialPage) root.showPage(fluxInitialPage)
    }
  }
}
