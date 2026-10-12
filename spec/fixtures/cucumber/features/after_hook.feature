Feature: Teardown

  @boom_after
  Scenario: Steps pass, teardown fails
    Given I am on the login page
    When I log in
