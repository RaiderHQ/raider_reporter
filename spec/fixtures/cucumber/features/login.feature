Feature: Login

  Scenario: A user can login
    Given I am on the login page
    When I log in
    Then I see the dashboard

  Scenario: A user is rejected
    Given I am on the login page
    When I fail on purpose
    Then I see the dashboard

  Scenario: A step is pending
    Given I am on the login page
    When I do something pending
    Then I see the dashboard

  Scenario: A step is undefined
    Given I am on the login page
    When nothing defines this step
    Then I see the dashboard

  Scenario: A step is ambiguous
    Given I am on the login page
    When I am ambiguous
