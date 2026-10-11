Feature: Background

  Background:
    Given I am on the login page
    And I fail on purpose

  Scenario: Never gets going
    When I log in
