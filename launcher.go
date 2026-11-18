package main

import (
	"crypto/sha256"
	"embed"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"unsafe"
)

//go:embed ClaudeAccounts/*
var assets embed.FS

func run() error {
	files, err := assets.ReadDir("ClaudeAccounts")
	if err != nil {
		return err
	}
	digest := sha256.New()
	contents := make(map[string][]byte)
	for _, f := range files {
		data, err := assets.ReadFile("ClaudeAccounts/" + f.Name())
		if err != nil {
			return err
		}
		digest.Write(data)
		contents[f.Name()] = data
	}
	base, err := os.UserCacheDir()
	if err != nil {
		return err
	}
	root := filepath.Join(base, "Claude Accounts Desktop")
	if err := os.MkdirAll(root, 0700); err != nil {
		return err
	}
	version := filepath.Join(root, fmt.Sprintf("%x", digest.Sum(nil)[:12]))
	if _, err := os.Stat(version); os.IsNotExist(err) {
		stage, err := os.MkdirTemp(root, "setup-")
		if err != nil {
			return err
		}
		defer os.RemoveAll(stage)
		for name, data := range contents {
			if err := os.WriteFile(filepath.Join(stage, name), data, 0600); err != nil {
				return err
			}
		}
		if err := os.Rename(stage, version); err != nil {
			if _, check := os.Stat(version); check != nil {
				return err
			}
		}
	}
	shell := filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	cmd := exec.Command(shell, "-NoLogo", "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", filepath.Join(version, "claude-switcher-gui.ps1"))
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("%v\n%s", err, out)
	}
	return nil
}
func main() {
	if err := run(); err != nil {
		msg, _ := syscall.UTF16PtrFromString(err.Error())
		title, _ := syscall.UTF16PtrFromString("Claude Accounts")
		syscall.NewLazyDLL("user32.dll").NewProc("MessageBoxW").Call(0, uintptr(unsafe.Pointer(msg)), uintptr(unsafe.Pointer(title)), 16)
	}
}
