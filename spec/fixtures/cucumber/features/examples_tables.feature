Feature: Tables

  Scenario Outline: Same labels
    Given I am on the login page
    When I greet <name>

    @smoke
    Examples:
      | name  |
      | alice |

    @regression
    Examples:
      | name |
      | bob  |

    Examples: Named
      | name  |
      | carol |
