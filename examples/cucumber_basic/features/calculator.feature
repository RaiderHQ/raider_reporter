Feature: Calculator

  @smoke
  Scenario: Adding numbers
    When I add 1 and 1
    Then the result is 2

  Scenario: A deliberate failure with an attachment
    When I add 2 and 2
    Then the result is 5

  Scenario Outline: Doubling
    When I add <n> and <n>
    Then the result is <double>

    Examples:
      | n | double |
      | 1 | 2      |
      | 2 | 4      |
