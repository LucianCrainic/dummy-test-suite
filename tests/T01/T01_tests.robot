*** Settings ***
Documentation    Test Suite 01 - Basic Tests with Pass/Fail Examples
Library          OperatingSystem
Library          String

*** Variables ***
${MESSAGE}       Hello, World!
${EXPECTED}      Hello, World!
${UNEXPECTED}    Goodbye, World!

*** Test Cases ***
T01_01 Passing Test - Verify String Match
    Should Be Equal    ${MESSAGE}    ${EXPECTED}
    Log    Test T01_01 Passed Successfully

T01_02 Failing Test - String Mismatch
    Should Be Equal    ${MESSAGE}    ${UNEXPECTED}
    Log    This log statement will not be executed due to failure

T01_03 Passing Test - Verify String Length
    ${length}=    Get Length    ${MESSAGE}
    Should Be True    ${length} > 5
    Log    String length verification passed

T01_04 Passing Test - File System Verification
    Directory Should Exist    ${CURDIR}
    Log    Current directory exists as expected

T01_05 Failing Test - Non-existent File
    File Should Exist    ${CURDIR}/non_existent_file.txt
    Log    This log statement will not be executed due to failure
