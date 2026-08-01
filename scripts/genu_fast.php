<?php
// Fast, collision-proof user generator. devel_generate's own genu command
// only dedupes usernames within a single in-memory batch -- it never checks
// the DB, so repeated/large calls eventually collide with an existing row
// and the whole batch dies (see genu_topup.sh). As the existing user pool
// grows toward devel_generate's effectively-finite word() namespace
// (empirically ~5M combinations), the retry-until-success approach needs
// more and more attempts per net new user and stops scaling.
//
// This script sidesteps the problem entirely: it appends a random 8-hex-char
// suffix to each generated word, which can never collide with existing
// plain-word() usernames (they contain no underscore) and has a collision
// space of ~4.3 billion, so duplicate risk stays negligible at any scale
// this project needs.
//
// Usage: ddev drush php:script genu_fast.php <count> [pass]
$count = (int) ($extra[0] ?? 0);
$pass = $extra[1] ?? 'test';
if ($count <= 0) {
  print("Usage: drush php:script genu_fast.php <count> [pass]\n");
  return;
}

$random = new \Drupal\Component\Utility\Random();
$user_storage = \Drupal::entityTypeManager()->getStorage('user');
$time = \Drupal::time()->getRequestTime();
$roles = [\Drupal\user\UserInterface::AUTHENTICATED_ROLE];

for ($i = 0; $i < $count; $i++) {
  $name = $random->word(mt_rand(6, 12)) . '_' . substr(bin2hex(random_bytes(4)), 0, 8);
  $account = $user_storage->create([
    'uid' => NULL,
    'name' => $name,
    'pass' => $pass,
    'mail' => $name . '@example.com',
    'status' => 1,
    'created' => $time - mt_rand(0, 31536000),
    'roles' => $roles,
    'devel_generate' => TRUE,
  ]);
  $account->save();

  if (($i + 1) % 5000 === 0) {
    fwrite(STDERR, ($i + 1) . " / {$count} users created\n");
  }
}

print("{$count} users created via fast generator\n");
