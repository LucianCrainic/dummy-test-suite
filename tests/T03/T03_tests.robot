*** Settings ***
Documentation    Test Suite 03 - List and Dictionary Operations
Library          Collections
Library          OperatingSystem

*** Variables ***
@{FRUITS}        apple    banana    orange
&{USER}          name=John    age=30    role=developer

*** Test Cases ***
T03_01 Passing Test - List Contains
    List Should Contain Value    ${FRUITS}    banana
    Log    List contains verification passed

T03_02 Failing Test - List Contains
    List Should Contain Value    ${FRUITS}    grape
    Log    This log statement will not be executed due to failure

T03_03 Passing Test - Dictionary Value
    Dictionary Should Contain Key    ${USER}    name
    ${name}=    Get From Dictionary    ${USER}    name
    Should Be Equal    ${name}    John
    Log    Dictionary test passed

T03_04 Passing Test - List Length
    Length Should Be    ${FRUITS}    3
    Log    List length verification passed

T03_05 Failing Test - Expected Error
    # This test is supposed to fail to demonstrate error handling
    Run Keyword And Expect Error    *    Fail    This test fails on purpose
    Log    Expected error test passed

T03_06 Failing Test - Invalid File Operation
    File Should Exist    ${CURDIR}/non_existent_file.txt
    Log    This log statement will not be executed due to failure
