Feature: Attachments

  Scenario: Raider attach in a step
    When I attach a screenshot with raider

  Scenario: Cucumber attach of a file
    When I attach a screenshot with cucumber

  Scenario: Cucumber attach of inline text
    When I attach inline text

  Scenario: Attach then flake
    When I attach a screenshot then fail on the first attempt
