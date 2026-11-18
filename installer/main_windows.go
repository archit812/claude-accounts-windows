package main

import (
	"bytes"
	_ "embed"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"unsafe"
)

//go:embed app.bin
var app []byte

//go:embed guide.txt
var guide []byte

func install() error {
	// CSIDL_DESKTOPDIRECTORY resolves the user's desktop, including redirection.
	var desktop [260]uint16
	result, _, _ := syscall.NewLazyDLL("shell32.dll").NewProc("SHGetFolderPathW").Call(0, 0x10, 0, 0, uintptr(unsafe.Pointer(&desktop[0])))
	if result != 0 {
		return fmt.Errorf("Could not locate your desktop (0x%x).", result)
	}
	dir := filepath.Join(syscall.UTF16ToString(desktop[:]), "Claude Accounts")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	for name, data := range map[string][]byte{"Claude Accounts.exe": app, "START HERE - Windows Guide.txt": guide} {
		path := filepath.Join(dir, name)
		old, err := os.ReadFile(path)
		if err == nil && bytes.Equal(old, data) {
			continue
		}
		if err == nil {
			return fmt.Errorf("A different copy of %s already exists. Move it aside before running setup again.", path)
		}
		if !os.IsNotExist(err) {
			return err
		}
		f, err := os.CreateTemp(dir, "setup-*")
		if err != nil {
			return err
		}
		defer os.Remove(f.Name())
		_, writeErr := f.Write(data)
		closeErr := f.Close()
		if writeErr != nil {
			return writeErr
		}
		if closeErr != nil {
			return closeErr
		}
		if err := os.Link(f.Name(), path); err != nil {
			if current, readErr := os.ReadFile(path); readErr != nil || !bytes.Equal(current, data) {
				return err
			}
		}
	}
	return exec.Command(filepath.Join(os.Getenv("SystemRoot"), "explorer.exe"), dir).Start()
}
func main() {
	if err := install(); err != nil {
		msg, _ := syscall.UTF16PtrFromString(err.Error())
		title, _ := syscall.UTF16PtrFromString("Claude Accounts Setup")
		syscall.NewLazyDLL("user32.dll").NewProc("MessageBoxW").Call(0, uintptr(unsafe.Pointer(msg)), uintptr(unsafe.Pointer(title)), 16)
	}
}
