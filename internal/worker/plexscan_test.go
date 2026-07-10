package worker

import "testing"

func TestPlexScanTarget(t *testing.T) {
	cases := []struct {
		name, dir, root string
		locs            []string
		want            string
		ok              bool
	}{
		{"basename remap (the live mismatch)", "/mnt/library/tv/Show/Season 01", "/mnt/library/tv",
			[]string{"/mnt/smedia/tv"}, "/mnt/smedia/tv/Show/Season 01", true},
		{"exact match unchanged", "/data/tv/Show", "/data/tv", []string{"/data/tv"}, "/data/tv/Show", true},
		{"single location remap", "/a/movies/M (2024)", "/a/movies", []string{"/plex/films"}, "/plex/films/M (2024)", true},
		{"trailing slash root", "/mnt/library/anime/X/S01", "/mnt/library/anime/", []string{"/mnt/smedia/anime"}, "/mnt/smedia/anime/X/S01", true},
		{"ambiguous multi → section scan", "/a/movies/M", "/a/movies", []string{"/p/x", "/p/y"}, "", false},
		{"no plex locations → section scan", "/a/movies/M", "/a/movies", nil, "", false},
		{"dir outside root → section scan", "/other/M", "/a/movies", []string{"/p/movies"}, "", false},

		// A sibling directory that merely shares a string prefix with the root is
		// NOT under the root. Splitting on the raw prefix yields a corrupt path
		// ("/p/movies" + "-4k/M"), and Plex silently no-ops on a path it doesn't
		// know — so the import never surfaces. Must fall back to a section scan.
		{"sibling prefix dir → section scan", "/a/movies-4k/M", "/a/movies", []string{"/p/movies"}, "", false},
		{"sibling prefix, exact-match loc → section scan", "/a/movies-4k/M", "/a/movies", []string{"/a/movies"}, "", false},
		{"sibling prefix, basename loc → section scan", "/a/movies-4k/M", "/a/movies", []string{"/p/movies", "/p/other"}, "", false},

		// dir == root is legitimately under the root (a whole-library rescan).
		{"dir equals root", "/a/movies", "/a/movies", []string{"/p/films"}, "/p/films", true},
		{"dir equals root with trailing slash", "/a/movies/", "/a/movies", []string{"/p/films"}, "/p/films", true},

		// The single-location fallback assumes the Plex location *equals* the Boxarr
		// root. When the location merely CONTAINS the root, Boxarr and Plex already
		// share the path — rebasing onto the location drops the intermediate
		// components and yields a folder Plex has never heard of (it answers 200 and
		// scans nothing). Same mount ⇒ pass the dir through untouched.
		{"plex location is a parent of root", "/media/movies/Film (2020)", "/media/movies",
			[]string{"/media"}, "/media/movies/Film (2020)", true},
		{"plex location is a parent, trailing slash", "/media/movies/Film", "/media/movies",
			[]string{"/media/"}, "/media/movies/Film", true},
		{"nested root beats basename remap", "/mnt/tv/anime/Show", "/mnt/tv/anime",
			[]string{"/mnt/tv"}, "/mnt/tv/anime/Show", true},
		// A parent-looking location that is only a string prefix is not a parent.
		{"parent-prefix sibling is not a parent", "/media2/movies/Film", "/media2/movies",
			[]string{"/media"}, "/media/Film", true},
	}
	for _, c := range cases {
		got, ok := plexScanTarget(c.dir, c.root, c.locs)
		if ok != c.ok || got != c.want {
			t.Errorf("%s: got (%q,%v), want (%q,%v)", c.name, got, ok, c.want, c.ok)
		}
	}
}
