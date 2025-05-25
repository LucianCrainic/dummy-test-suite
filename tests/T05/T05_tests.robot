*** Settings ***
Documentation    Test Suite 05 - File Operations and String Manipulation
Library          OperatingSystem
Library          String
Library          Collections

*** Variables ***
${TEST_FILE}     ${CURDIR}/test_file.txt
${TEST_CONTENT}  This is a test file content for Robot Framework tests.
${SEARCH_STRING}  test file
${TEST_DIR}      ${CURDIR}/test_directory

*** Test Cases ***
T05_01 Passing Test - Create and Read File
    Create File    ${TEST_FILE}    ${TEST_CONTENT}
    ${content}=    Get File    ${TEST_FILE}
    Should Be Equal    ${content}    ${TEST_CONTENT}
    File Should Exist    ${TEST_FILE}
    Log    File creation and reading test passed

T05_02 Passing Test - String Operations
    ${upper}=    Convert To Uppercase    ${TEST_CONTENT}
    Should Not Be Equal    ${upper}    ${TEST_CONTENT}
    Should Be Equal    ${upper}    ${TEST_CONTENT.upper()}
    ${contains}=    Run Keyword And Return Status    Should Contain    ${TEST_CONTENT}    ${SEARCH_STRING}
    Should Be True    ${contains}
    Log    String operations test passed

T05_03 Passing Test - Directory Operations
    Create Directory    ${TEST_DIR}
    Directory Should Exist    ${TEST_DIR}
    Create File    ${TEST_DIR}/file1.txt    Content of file 1
    Create File    ${TEST_DIR}/file2.txt    Content of file 2
    @{files}=    List Files In Directory    ${TEST_DIR}
    Length Should Be    ${files}    2
    Log    Directory operations test passed

T05_04 Failing Test - Invalid File Operation
    Run Keyword And Expect Error    *    Get File    ${CURDIR}/non_existent_file.txt
    Log    This log statement should not be executed due to error

T05_05 Passing Test - String Splitting and Joining
    @{words}=    Split String    ${TEST_CONTENT}
    ${word_count}=    Get Length    ${words}
    Should Be True    ${word_count} > 5
    ${joined}=    Catenate    SEPARATOR=-    @{words}
    Should Contain    ${joined}    -
    Should Not Be Equal    ${joined}    ${TEST_CONTENT}
    Log    String splitting and joining test passed

*** Keywords ***
Cleanup Test Files
    [Documentation]    Cleanup files and directories created during tests
    Remove File    ${TEST_FILE}    
    Remove Directory    ${TEST_DIR}    recursive=True
