// These one should be skipped:
// -------------------------------
// TODO(http://issue-tracker.com/user/repo/10)
// TODO(http://issue-tracker.com/user/repo/10) content of todo
// TODO(http://issue-tracker.com/user/repo/10): content of todo
// TODO(https://issue-tracker.com/user/repo/10)
// TODO(https://issue-tracker.com/user/repo/10) content of todo
// TODO(https://issue-tracker.com/user/repo/10): content of todo
// TODO(#10)
// TODO(#10) content of todo
// TODO(#10): content of todo
// TODO fix in #10
// TODO: fix in https://issue-tracker.com/user/repo/10

// These ones will be caught:
// -------------------------------
// TODO()
// TODO
// TODO: content
// TODO content of todo
// TODO(): content
// TODO(10) this will be caught
