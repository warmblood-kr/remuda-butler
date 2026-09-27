@isolated-daemon
Feature: Display Butler sessions as a team tree

  Scenario: Render roots and nested teams parent first
    Given an isolated daemon has two roots and nested members
    When I list Butler sessions
    Then each parent precedes its descendants
    And siblings are ordered by display alias

  Scenario: Preserve roots, orphans, and cycles
    Given the isolated registry has roots, a missing-parent orphan, and a disconnected cycle
    When I list Butler sessions
    Then each record appears exactly once
    And the orphan is marked and retains its missing parent value
    And traversal terminates

  Scenario: Bound indentation without shifting tabular columns
    Given the isolated registry has a team deeper than twenty levels
    When I list Butler sessions
    Then only the session display column is indented by two spaces per level up to forty spaces
    And there are no blank rows

  Scenario: Test a private live-image replacement and restart
    Given a private daemon has a recorded process ID and image identity
    When only the sessions renderer is replaced and the roster is listed
    Then the daemon process and image identity remain unchanged
    When the private daemon is restarted
    Then the replacement is absent from the new Lua image
