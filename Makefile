GO ?= go
export GOOS := windows
export GOARCH := amd64
export CGO_ENABLED := 0
FLAGS := -trimpath -ldflags="-s -w -H windowsgui"

.PHONY: all
all:
	mkdir -p dist
	$(GO) build $(FLAGS) -o 'dist/Claude Accounts.exe' launcher.go
	cp 'dist/Claude Accounts.exe' installer/app.bin
	cp 'START HERE - Windows Guide.txt' installer/guide.txt
	$(GO) build $(FLAGS) -o dist/Makefile.exe installer/main_windows.go
	cp 'START HERE - Windows Guide.txt' dist/
	cd dist && zip -q 'Claude Accounts for Windows.zip' 'Claude Accounts.exe' 'START HERE - Windows Guide.txt'
