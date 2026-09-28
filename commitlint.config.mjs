export default {
  extends: ['@commitlint/config-conventional'],
  ignores: [
    (message) => message.startsWith('Merge '),
    (message) => /^chore\(changelog\):/i.test(message),
    // Dependabot's bodies list release-note links longer than the 100-character
    // limit. Its subjects get a Conventional prefix (.github/dependabot.yml),
    // and Lint PR still checks the PR title the squash merge uses.
    (message) => /^Signed-off-by: dependabot\[bot\] <support@github\.com>$/m.test(message),
  ],
};
