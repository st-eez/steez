package installer

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestCreateSymlink_HappyPath(t *testing.T) {
	tmp := t.TempDir()
	source := filepath.Join(tmp, "source")
	target := filepath.Join(tmp, "target")
	os.Mkdir(source, 0o755)

	if err := CreateSymlink(source, target, false, false); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	resolved, err := os.Readlink(target)
	if err != nil {
		t.Fatalf("target is not a symlink: %v", err)
	}
	if resolved != source {
		t.Errorf("symlink points to %s, want %s", resolved, source)
	}
}

func TestCreateSymlink_TargetExistsFile(t *testing.T) {
	tmp := t.TempDir()
	source := filepath.Join(tmp, "source")
	target := filepath.Join(tmp, "target")
	os.Mkdir(source, 0o755)
	os.WriteFile(target, []byte("real file"), 0o644)

	err := CreateSymlink(source, target, false, false)
	if !errors.Is(err, ErrTargetExists) {
		t.Errorf("got %v, want ErrTargetExists", err)
	}
}

func TestCreateSymlink_TargetExistsSameSymlink(t *testing.T) {
	tmp := t.TempDir()
	source := filepath.Join(tmp, "source")
	target := filepath.Join(tmp, "target")
	os.Mkdir(source, 0o755)
	os.Symlink(source, target)

	err := CreateSymlink(source, target, false, false)
	if err != nil {
		t.Errorf("expected nil (idempotent), got %v", err)
	}
}

func TestCreateSymlink_TargetExistsDifferentSymlink(t *testing.T) {
	tmp := t.TempDir()
	source := filepath.Join(tmp, "source")
	other := filepath.Join(tmp, "other")
	target := filepath.Join(tmp, "target")
	os.Mkdir(source, 0o755)
	os.Mkdir(other, 0o755)
	os.Symlink(other, target)

	err := CreateSymlink(source, target, false, false)
	if !errors.Is(err, ErrSymlinkExists) {
		t.Errorf("got %v, want ErrSymlinkExists", err)
	}
}

func TestCreateSymlink_SourceMissing(t *testing.T) {
	tmp := t.TempDir()
	source := filepath.Join(tmp, "nonexistent")
	target := filepath.Join(tmp, "target")

	err := CreateSymlink(source, target, false, false)
	if !errors.Is(err, ErrSourceMissing) {
		t.Errorf("got %v, want ErrSourceMissing", err)
	}
}

func TestCreateSymlink_DryRun(t *testing.T) {
	tmp := t.TempDir()
	source := filepath.Join(tmp, "source")
	target := filepath.Join(tmp, "target")
	os.Mkdir(source, 0o755)

	if err := CreateSymlink(source, target, true, false); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if _, err := os.Lstat(target); !os.IsNotExist(err) {
		t.Error("dry run should not create symlink")
	}
}

func TestCreateSymlink_Force(t *testing.T) {
	tmp := t.TempDir()
	source := filepath.Join(tmp, "source")
	other := filepath.Join(tmp, "other")
	target := filepath.Join(tmp, "target")
	os.Mkdir(source, 0o755)
	os.Mkdir(other, 0o755)
	os.Symlink(other, target)

	if err := CreateSymlink(source, target, false, true); err != nil {
		t.Fatalf("unexpected error with force: %v", err)
	}

	resolved, _ := os.Readlink(target)
	if resolved != source {
		t.Errorf("after force, symlink points to %s, want %s", resolved, source)
	}
}

func TestRemoveSymlink_RealDir(t *testing.T) {
	tmp := t.TempDir()
	target := filepath.Join(tmp, "realdir")
	os.Mkdir(target, 0o755)

	err := RemoveSymlink(target)
	if !errors.Is(err, ErrNotSymlink) {
		t.Errorf("got %v, want ErrNotSymlink", err)
	}
}
