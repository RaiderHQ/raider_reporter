Feature: Comparison retry

  Scenario: Compare then flake
    When I record a comparison that is failed on the first attempt
    Then I see the dashboard
