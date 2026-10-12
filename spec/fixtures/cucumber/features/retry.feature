Feature: Retry

  Scenario: Flaky then fine
    Given I am on the login page
    When I fail on the first attempt
    Then I see the dashboard

  @always_fail
  Scenario: Never recovers
    Given I am on the login page
    When I fail on purpose
