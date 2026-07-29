# ClaudeSwitch — atajos de construcción y prueba.

APP = ClaudeSwitch.app
INSTALLED = /Applications/$(APP)

.PHONY: build test app install run stop clean

## Compila el binario en debug.
build:
	swift build

## Ejecuta los tests.
test:
	swift test

## Ensambla y firma ClaudeSwitch.app. Para firma estable: make app SIGN="ClaudeSwitch Self-Signed"
app:
	scripts/build-app.sh $(SIGN)

## Copia ClaudeSwitch.app a /Applications.
install: app
	rm -rf "$(INSTALLED)"
	cp -R "$(APP)" /Applications/
	@echo "Instalada en $(INSTALLED)"

## Lanza la app instalada.
run:
	open "$(INSTALLED)"

## Cierra la app si está corriendo.
stop:
	-pkill -x ClaudeSwitch || true

## Borra los artefactos de build.
clean:
	rm -rf .build "$(APP)"
