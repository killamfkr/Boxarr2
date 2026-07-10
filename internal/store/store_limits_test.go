package store

import (
	"context"
	"testing"
	"time"

	"github.com/radaiko/boxarr/internal/job"
	"github.com/radaiko/boxarr/internal/media"
)

func TestLimitEvents(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := st.RecordLimitEvent(ctx, "rate_limit", "after 12 grabs"); err != nil {
		t.Fatal(err)
	}
	evs, err := st.ListLimitEvents(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(evs) != 1 || evs[0].Kind != "rate_limit" || evs[0].Detail != "after 12 grabs" {
		t.Fatalf("events = %+v", evs)
	}
}

func TestCountJobsSubmittedSince(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	jid, err := st.CreateJob(ctx, &job.Job{State: job.StateImported, NZBName: "a", MediaType: "movie"})
	if err != nil {
		t.Fatal(err)
	}
	j, _ := st.GetJob(ctx, jid)
	now := time.Now()
	j.SubmittedAt = &now
	if err := st.UpdateJob(ctx, j); err != nil {
		t.Fatal(err)
	}
	if n, _ := st.CountJobsSubmittedSince(ctx, now.Add(-time.Hour), "usenet"); n != 1 {
		t.Errorf("count since 1h ago = %d, want 1", n)
	}
	if n, _ := st.CountJobsSubmittedSince(ctx, now.Add(time.Hour), "usenet"); n != 0 {
		t.Errorf("count since 1h ahead = %d, want 0", n)
	}
}

// Torrent submissions must not consume the usenet hourly create budget: TorBox
// meters the two independently (60 NZB/hour vs 300 torrents/min), so counting
// torrents against the usenet cap silently freezes usenet submission.
func TestCountJobsSubmittedSinceIsPerProtocol(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	now := time.Now()
	mk := func(name, proto string) {
		jid, err := st.CreateJob(ctx, &job.Job{
			State: job.StateQueued, NZBName: name, MediaType: "movie", Protocol: proto,
		})
		if err != nil {
			t.Fatal(err)
		}
		j, _ := st.GetJob(ctx, jid)
		j.SubmittedAt = &now
		if err := st.UpdateJob(ctx, j); err != nil {
			t.Fatal(err)
		}
	}
	mk("nzb", "usenet")
	mk("tor1", "torrent")
	mk("tor2", "torrent")

	since := now.Add(-time.Hour)
	if n, _ := st.CountJobsSubmittedSince(ctx, since, "usenet"); n != 1 {
		t.Errorf("usenet count = %d, want 1 (torrents must not count)", n)
	}
	if n, _ := st.CountJobsSubmittedSince(ctx, since, "torrent"); n != 2 {
		t.Errorf("torrent count = %d, want 2", n)
	}
}

// ResetImportLinks once wrote job_id=0 into a column declared
// REFERENCES jobs(id); jobs.id is AUTOINCREMENT and never 0, so with
// _pragma=foreign_keys(1) every call that matched a row aborted with
// FOREIGN KEY constraint failed. Its only caller (rollbackImport) logged the
// error and carried on deleting the job, stranding the row as permanently
// "downloaded" while its symlink was gone from disk.
func TestResetImportLinksClearsRowsAndDoesNotViolateFK(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()

	jid, err := st.CreateJob(ctx, &job.Job{State: job.StateImported, NZBName: "rel", MediaType: "movie"})
	if err != nil {
		t.Fatal(err)
	}
	// monitored + a past release_date, so the wanted sweep would pick it up once
	// the rollback restores it.
	mid, err := st.CreateMovie(ctx, &media.Movie{
		TMDBID: 42, Title: "T", Monitored: true, ReleaseDate: "2020-01-01",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.Exec(ctx,
		`UPDATE movie SET has_file=1, status='downloaded', library_path='/lib/T.mkv', job_id=? WHERE id=?`,
		jid, mid); err != nil {
		t.Fatal(err)
	}

	if err := st.ResetImportLinks(ctx, jid); err != nil {
		t.Fatalf("ResetImportLinks: %v", err)
	}

	m, err := st.GetMovie(ctx, mid)
	if err != nil {
		t.Fatal(err)
	}
	if m.HasFile {
		t.Error("has_file still set after rollback")
	}
	if m.LibraryPath != "" {
		t.Errorf("library_path = %q, want empty", m.LibraryPath)
	}
	if m.Status != "missing" {
		t.Errorf("status = %q, want missing", m.Status)
	}
	// The row must be re-searchable, i.e. actually returned by the wanted sweep.
	wanted, err := st.WantedMovies(ctx)
	if err != nil {
		t.Fatal(err)
	}
	for _, w := range wanted {
		if w.ID == mid {
			return
		}
	}
	t.Error("rolled-back movie is not in WantedMovies; it can never be re-grabbed")
}
