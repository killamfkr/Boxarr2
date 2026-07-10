package worker

import (
	"context"
	"sync"
	"testing"

	"github.com/radaiko/boxarr/internal/plex"
	"github.com/radaiko/boxarr/internal/settings"
)

// fakeScanner records section scans; other PlexScanner methods are unused here.
type fakeScanner struct {
	mu       sync.Mutex
	sections []string
}

func (f *fakeScanner) ScanPath(context.Context, string, string) error { return nil }
func (f *fakeScanner) ScanSection(_ context.Context, sectionID string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sections = append(f.sections, sectionID)
	return nil
}
func (f *fakeScanner) SectionLocations(context.Context, string) ([]string, error) { return nil, nil }
func (f *fakeScanner) SectionItems(context.Context, string, int) ([]plex.LibItem, error) {
	return nil, nil
}
func (f *fakeScanner) ShowEpisodes(context.Context, string) ([]plex.LibItem, error) { return nil, nil }
func (f *fakeScanner) ItemStreams(context.Context, string) (int, []plex.Stream, []plex.Stream, error) {
	return 0, nil, nil, nil
}
func (f *fakeScanner) SetDefaultStreams(context.Context, int, int, int) error { return nil }

func TestScanPlexLibrariesScansEachConfiguredSection(t *testing.T) {
	fake := &fakeScanner{}
	w, _, _ := testWorkers(t, &fakeTorBox{})
	w.SetPlex(fake)
	ctx := context.Background()
	_ = w.set.Set(ctx, settings.KeyPlexURL, "http://plex:32400")
	_ = w.set.Set(ctx, settings.KeyPlexToken, "tok")
	_ = w.set.Set(ctx, settings.KeyPlexMovieSection, "12")
	_ = w.set.Set(ctx, settings.KeyPlexTVSection, "13")
	_ = w.set.Set(ctx, settings.KeyPlexAnimeSection, "14")

	if err := w.ScanPlexLibraries(ctx); err != nil {
		t.Fatalf("ScanPlexLibraries: %v", err)
	}
	got := map[string]bool{}
	for _, s := range fake.sections {
		got[s] = true
	}
	for _, want := range []string{"12", "13", "14"} {
		if !got[want] {
			t.Errorf("section %s was not scanned; scanned=%v", want, fake.sections)
		}
	}
}

func TestScanPlexLibrariesDedupesSharedSection(t *testing.T) {
	fake := &fakeScanner{}
	w, _, _ := testWorkers(t, &fakeTorBox{})
	w.SetPlex(fake)
	ctx := context.Background()
	_ = w.set.Set(ctx, settings.KeyPlexURL, "http://plex:32400")
	_ = w.set.Set(ctx, settings.KeyPlexToken, "tok")
	_ = w.set.Set(ctx, settings.KeyPlexMovieSection, "12")
	_ = w.set.Set(ctx, settings.KeyPlexTVSection, "13")
	// Anime shares the TV section (common setup) → must not scan 13 twice.
	_ = w.set.Set(ctx, settings.KeyPlexAnimeSection, "13")

	if err := w.ScanPlexLibraries(ctx); err != nil {
		t.Fatalf("ScanPlexLibraries: %v", err)
	}
	if len(fake.sections) != 2 {
		t.Errorf("expected 2 distinct section scans, got %v", fake.sections)
	}
}

// pathScanner records partial scans and reports one Plex-side location.
type pathScanner struct {
	fakeScanner
	locs  []string
	paths []string
}

func (p *pathScanner) SectionLocations(context.Context, string) ([]string, error) {
	return p.locs, nil
}
func (p *pathScanner) ScanPath(_ context.Context, _ string, path string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.paths = append(p.paths, path)
	return nil
}

// With no dedicated anime section, anime imports scan the TV section. The remap
// must therefore be computed against the TV root — otherwise the anime path
// component is dropped and Plex silently no-ops on a folder it doesn't know,
// so the import never surfaces in the library.
func TestMaybePlexScanAnimeFallsBackToTVSectionRoot(t *testing.T) {
	fake := &pathScanner{locs: []string{"/mnt/smedia/tv"}}
	w, _, _ := testWorkers(t, &fakeTorBox{})
	w.SetPlex(fake)
	ctx := context.Background()
	_ = w.set.Set(ctx, settings.KeyPlexURL, "http://plex:32400")
	_ = w.set.Set(ctx, settings.KeyPlexToken, "tok")
	_ = w.set.Set(ctx, settings.KeyPlexTVSection, "13")
	_ = w.set.Set(ctx, settings.KeyPlexAnimeSection, "") // no anime section
	_ = w.set.Set(ctx, settings.KeyTVLibraryRoot, "/mnt/library/tv")
	_ = w.set.Set(ctx, settings.KeyAnimeLibraryRoot, "/mnt/library/tv/anime")

	w.maybePlexScan(ctx, "/mnt/library/tv/anime/Show/Season 01", "anime")

	want := "/mnt/smedia/tv/anime/Show/Season 01"
	if len(fake.paths) != 1 || fake.paths[0] != want {
		t.Errorf("partial scan paths = %v, want [%s] (sections=%v)", fake.paths, want, fake.sections)
	}
}
