@smoke
Feature: Greetings

  @login
  Scenario Outline: Greet users
    Given I am on the login page
    When I greet <name>

    @admin
    Examples: Admins
      | name  |
      | alice |
      | bob   |

    Examples:
      | name  |
      | carol |
      | dave  |
