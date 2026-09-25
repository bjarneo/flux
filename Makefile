PREFIX  ?= /usr
DESTDIR ?=
GO      ?= go
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
GO_LDFLAGS := -s -w -X main.version=$(VERSION)

GUI_BUILD  := gui/app/build
PLUGIN_DIR ?= $(HOME)/.config/omarchy/plugins/flux
PLUGIN_FILES := manifest.json Service.qml Backend.qml BarWidget.qml Panel.qml

# copy-plugin DEST copies the plugin in the layout that `omarchy plugin
# validate` accepts: real files, the shared views in Flux/, and no tools/.
define copy-plugin
	mkdir -p $(1)/Flux
	for f in $(PLUGIN_FILES); do install -m644 gui/omarchy/$$f $(1)/$$f; done
	cd gui/qml && find . -path ./tools -prune -o -type f \( -name '*.qml' -o -name qmldir -o -name '*.js' \) -print | \
		while read -r f; do install -Dm644 "$$f" "$(1)/Flux/$$f"; done
endef

.PHONY: build build-go build-gui test vet install install-user install-plugin uninstall uninstall-user uninstall-plugin dev open snapshot android clean

build: build-go build-gui

build-go:
	$(GO) build -trimpath -ldflags "$(GO_LDFLAGS)" -o bin/fluxd ./cmd/fluxd
	$(GO) build -trimpath -ldflags "$(GO_LDFLAGS)" -o bin/flux ./cmd/flux
	@# The PAM helper is static, so that it depends on no shared library.
	CGO_ENABLED=0 $(GO) build -trimpath -ldflags "$(GO_LDFLAGS)" -o bin/flux-approve ./cmd/flux-approve

# The Qt6 C++ app. The shared views in gui/qml are compiled into it.
build-gui:
	cmake -S gui/app -B $(GUI_BUILD) -G Ninja -DCMAKE_BUILD_TYPE=Release -DFLUX_VERSION="$(VERSION)"
	cmake --build $(GUI_BUILD)

test:
	$(GO) test -race ./cmd/... ./internal/...

vet:
	$(GO) vet ./cmd/... ./internal/...
	@out=$$(gofmt -l cmd internal); if [ -n "$$out" ]; then echo "Run gofmt -w on:"; echo "$$out"; exit 1; fi

# install copies what `make build` made. It does not build, so that
# `sudo make install` works without Go on the PATH of root. On a real
# install (no DESTDIR), it also runs the system setup in post-install.sh.
install:
	@test -x bin/fluxd -a -x bin/flux -a -x bin/flux-approve -a -x $(GUI_BUILD)/flux-gui || { echo "Run make first, then sudo make install"; exit 1; }
	install -Dm755 bin/fluxd $(DESTDIR)$(PREFIX)/bin/fluxd
	install -Dm755 bin/flux $(DESTDIR)$(PREFIX)/bin/flux
	install -Dm755 $(GUI_BUILD)/flux-gui $(DESTDIR)$(PREFIX)/bin/flux-gui
	@# The PAM helper for approval with a fingerprint. PAM uses it only
	@# after the user adds it to a PAM file.
	install -Dm755 bin/flux-approve $(DESTDIR)$(PREFIX)/lib/flux/flux-approve
	$(call copy-plugin,$(DESTDIR)$(PREFIX)/share/flux/omarchy-plugin)
	install -Dm644 dist/fluxd.service $(DESTDIR)$(PREFIX)/lib/systemd/user/fluxd.service
	install -Dm644 dist/61-flux-v4l2loopback.rules $(DESTDIR)$(PREFIX)/lib/udev/rules.d/61-flux-v4l2loopback.rules
	@# Earlier versions installed these 2 files for the phone touchpad.
	rm -f $(DESTDIR)$(PREFIX)/lib/udev/rules.d/60-flux-uinput.rules $(DESTDIR)$(PREFIX)/lib/modules-load.d/flux-uinput.conf
	install -Dm644 dist/flux.desktop $(DESTDIR)$(PREFIX)/share/applications/flux.desktop
	install -Dm644 dist/flux.svg $(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps/flux.svg
	install -Dm644 dist/flux-symbolic.svg $(DESTDIR)$(PREFIX)/share/icons/hicolor/symbolic/apps/flux-symbolic.svg
	install -Dm755 dist/post-install.sh $(DESTDIR)$(PREFIX)/share/flux/post-install.sh
	install -Dm755 dist/pre-remove.sh $(DESTDIR)$(PREFIX)/share/flux/pre-remove.sh
	@if [ -z "$(DESTDIR)" ]; then sh dist/post-install.sh; fi

uninstall:
	@if [ -z "$(DESTDIR)" ]; then sh dist/pre-remove.sh; fi
	rm -f $(DESTDIR)$(PREFIX)/bin/fluxd $(DESTDIR)$(PREFIX)/bin/flux $(DESTDIR)$(PREFIX)/bin/flux-gui
	rm -rf $(DESTDIR)$(PREFIX)/share/flux
	rm -rf $(DESTDIR)$(PREFIX)/lib/flux
	rm -f $(DESTDIR)$(PREFIX)/lib/systemd/user/fluxd.service
	rm -f $(DESTDIR)$(PREFIX)/lib/udev/rules.d/61-flux-v4l2loopback.rules
	rm -f $(DESTDIR)$(PREFIX)/share/applications/flux.desktop
	rm -f $(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps/flux.svg
	rm -f $(DESTDIR)$(PREFIX)/share/icons/hicolor/symbolic/apps/flux-symbolic.svg

# Add the flux plugin to omarchy-shell for this user. The shared views are
# copied into the plugin, because omarchy-shell loads only files inside it.
install-plugin:
	rm -rf $(PLUGIN_DIR)
	$(call copy-plugin,$(PLUGIN_DIR))
	omarchy plugin validate $(PLUGIN_DIR) || true
	@echo "To load it, run: omarchy-shell shell rescanPlugins && omarchy plugin enable flux --section right"

uninstall-plugin:
	rm -rf $(PLUGIN_DIR)

# install-user installs Flux for the current user in ~/.local, with no root:
# the binaries, the desktop entry, and the icons. The system parts (the udev
# rule, the kernel module, and the PAM helper) need `sudo make install`.
# Then run `flux setup` for the fluxd service and the plugin.
USER_PREFIX ?= $(HOME)/.local
install-user:
	@test -x bin/fluxd -a -x bin/flux -a -x $(GUI_BUILD)/flux-gui || { echo "Run make first"; exit 1; }
	install -Dm755 bin/fluxd $(USER_PREFIX)/bin/fluxd
	install -Dm755 bin/flux $(USER_PREFIX)/bin/flux
	install -Dm755 $(GUI_BUILD)/flux-gui $(USER_PREFIX)/bin/flux-gui
	install -Dm644 dist/flux.desktop $(USER_PREFIX)/share/applications/flux.desktop
	install -Dm644 dist/flux.svg $(USER_PREFIX)/share/icons/hicolor/scalable/apps/flux.svg
	install -Dm644 dist/flux-symbolic.svg $(USER_PREFIX)/share/icons/hicolor/symbolic/apps/flux-symbolic.svg
	-gtk-update-icon-cache -q -t $(USER_PREFIX)/share/icons/hicolor 2>/dev/null
	-update-desktop-database -q $(USER_PREFIX)/share/applications 2>/dev/null

uninstall-user:
	rm -f $(USER_PREFIX)/bin/fluxd $(USER_PREFIX)/bin/flux $(USER_PREFIX)/bin/flux-gui
	rm -f $(USER_PREFIX)/share/applications/flux.desktop
	rm -f $(USER_PREFIX)/share/icons/hicolor/scalable/apps/flux.svg $(USER_PREFIX)/share/icons/hicolor/symbolic/apps/flux-symbolic.svg

# Run fluxd from the checkout in the foreground.
dev: build-go
	./bin/fluxd

# Open the window from the checkout: the plugin when it is enabled, else
# flux-gui from gui/app/build.
open: build
	./bin/flux open

# Render every screen into PNG files without a display.
snapshot: build-gui
	mkdir -p snapshots
	QT_QPA_PLATFORM=offscreen $(GUI_BUILD)/flux-gui --snapshot $(CURDIR)/snapshots

android:
	cd android && ./gradlew :app:assembleDebug

clean:
	rm -rf bin $(GUI_BUILD) snapshots
