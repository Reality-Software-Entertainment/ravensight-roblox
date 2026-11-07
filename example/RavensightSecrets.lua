-- ServerStorage is never sent to players, so the key and the salt stay on
-- the server. Replace both before publishing, and never change the salt
-- afterwards: every player's device id is derived from it.
return {
  ingestKey = 'gt_live_replace_me',
  salt = 'replace-with-at-least-16-random-characters',
}
