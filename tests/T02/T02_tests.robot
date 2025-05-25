*** Settings ***
Documentation    Test Suite 02 - Math and Calculation Tests
Library          BuiltIn

*** Variables ***
${NUM_A}         10
${NUM_B}         5
${EXPECTED_SUM}  15
${WRONG_SUM}     16
${TIMEOUT}       1s

*** Test Cases ***
T02_01 Passing Test - Addition
    ${result}=    Evaluate    ${NUM_A} + ${NUM_B}
    Should Be Equal As Integers    ${result}    ${EXPECTED_SUM}
    Log    Addition test passed

T02_02 Failing Test - Wrong Addition
    ${result}=    Evaluate    ${NUM_A} + ${NUM_B}
    Should Be Equal As Integers    ${result}    ${WRONG_SUM}
    Log    This log statement will not be executed due to failure

T02_03 Passing Test - Multiplication
    ${result}=    Evaluate    ${NUM_A} * ${NUM_B}
    Should Be Equal As Integers    ${result}    50
    Log    Multiplication test passed

T02_04 Failing Test - Division By Zero
    ${result}=    Evaluate    ${NUM_A} / 0
    Log    This log statement will not be executed due to failure

T02_05 Passing Test - Greater Than Comparison
    Should Be True    ${NUM_A} > ${NUM_B}
    Log    Comparison test passed

T02_06 Failing Test - Timeout
    [Timeout]    ${TIMEOUT}
    Sleep    2s
    Log    This log statement will not be executed due to timeout
