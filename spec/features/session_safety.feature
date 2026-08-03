Feature: Managed agent session safety
  Destructive actions must fail closed and always target immutable tmux identities.

  @test-id:immutable-session-open
  Scenario: A stale picker row cannot open a same-name replacement
    Given a picker row captured an immutable tmux session ID
    And the original display name can be reused
    When the user opens the stale row
    Then tmux is targeted only by the captured immutable session ID

  @test-id:protected-bulk-kill
  Scenario: Current blocked state protects a renamed session
    Given a matched session row was previously idle
    And the current daemon snapshot reports the same immutable ID as blocked
    When the user confirms bulk deletion
    Then the blocked session is not killed

  @test-id:malformed-state-fails-closed
  Scenario: Malformed daemon state aborts destructive work
    Given one matched managed session is eligible for deletion
    And the current daemon state contains malformed data
    When the user confirms bulk deletion
    Then no matched session is killed

  @test-id:unseen-completion
  Scenario: An unwatched completed turn becomes done
    Given an agent pane was working
    And no client is watching that pane
    When screen detection observes idle
    Then the state becomes done until it is seen

  @test-id:native-history-resume
  Scenario: Saved conversations use each agent's native resume mechanism
    Given a saved Pi, Codex, or Claude conversation
    When the user resumes it from history mode
    Then the configured agent command receives its native resume reference
