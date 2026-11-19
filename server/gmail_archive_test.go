package main

import (
	"testing"

	"github.com/emersion/go-imap/v2"
)

func TestGmailArchiveLabelDoesNotReplaceAllMail(t *testing.T) {
	// Gmail's mailboxes, plus a user label someone named Archive.
	list := []*imap.ListData{
		{Mailbox: "INBOX"},
		{Mailbox: "Archive"},
		{Mailbox: "[Gmail]/All Mail", Attrs: []imap.MailboxAttr{imap.MailboxAttrAll}},
		{Mailbox: "[Gmail]/Sent Mail", Attrs: []imap.MailboxAttr{imap.MailboxAttrSent}},
	}
	found, archiveIsAll := chooseMailboxes(list, true, nil)
	if found[RoleArchive] != "[Gmail]/All Mail" || !archiveIsAll {
		t.Fatalf("Gmail's archive must be All Mail, got %q (all mail %v)", found[RoleArchive], archiveIsAll)
	}
	// Elsewhere, such as Proton Mail Bridge, a mailbox named Archive is the archive.
	found, archiveIsAll = chooseMailboxes(list, false, nil)
	if found[RoleArchive] != "Archive" || archiveIsAll {
		t.Fatalf("outside Gmail the Archive mailbox should win, got %q", found[RoleArchive])
	}
	// A configured name always wins.
	found, _ = chooseMailboxes(list, true, map[Role]string{RoleArchive: "Archive"})
	if found[RoleArchive] != "Archive" {
		t.Fatalf("a configured archive must win, got %q", found[RoleArchive])
	}
}
