# SwitchBar — atajos de construcción y prueba.

APP = SwitchBar.app
INSTALLED = /Applications/$(APP)

VERSION = 1.0.0-beta.2

.PHONY: build test app install run stop clean dmg notarize

## Compila el binario en debug.
build:
	swift build

## Ejecuta los tests.
test:
	swift test

## Ensambla y firma SwitchBar.app (detecta sola la identidad local estable).
app:
	scripts/build-app.sh "$(SIGN)"

## Copia SwitchBar.app a /Applications.
install: app
	rm -rf "$(INSTALLED)"
	cp -R "$(APP)" /Applications/
	@echo "Instalada en $(INSTALLED)"

## Lanza la app instalada.
run:
	open "$(INSTALLED)"

## Cierra la app si está corriendo.
stop:
	-pkill -x SwitchBar || true

## Empaqueta la app en un DMG de distribución con su SHA-256.
dmg: app
	scripts/make-dmg.sh "$(VERSION)"

## Notariza el DMG y adjunta el ticket (requiere credenciales guardadas).
notarize:
	scripts/notarize.sh "SwitchBar-$(VERSION).dmg"

## Borra los artefactos de build.
clean:
	rm -rf .build "$(APP)" SwitchBar-*.dmg SwitchBar-*.dmg.sha256
