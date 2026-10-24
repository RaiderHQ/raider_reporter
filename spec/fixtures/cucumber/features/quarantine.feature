Feature: Quarantine

  Scenario: A stable check
    Given I am on the login page

  Scenario: A known flaky failure
    Given I am on the login page
    When I fail on purpose
