*** Settings ***
Documentation    Test Suite 04 - HTTP and API Testing
Library          RequestsLibrary
Library          Collections
Library          String

*** Variables ***
${BASE_URL}      https://httpbin.org
${ENDPOINT}      /anything
${PARAM_KEY}     test_param
${PARAM_VALUE}   test_value
&{HEADERS}       Content-Type=application/json    Accept=application/json

*** Test Cases ***
T04_01 Passing Test - GET Request Status Code
    Create Session    httpbin    ${BASE_URL}    verify=True
    ${response}=    GET On Session    httpbin    ${ENDPOINT}    expected_status=200
    Should Be Equal As Strings    ${response.status_code}    200
    Log    GET request test passed

T04_02 Passing Test - POST Request With Payload
    Create Session    httpbin    ${BASE_URL}    verify=True
    &{data}=    Create Dictionary    name=Robot    framework=Test
    ${response}=    POST On Session    httpbin    ${ENDPOINT}    json=${data}    headers=${HEADERS}    expected_status=200
    Dictionary Should Contain Key    ${response.json()}    json
    Dictionary Should Contain Key    ${response.json()["json"]}    name
    Should Be Equal    ${response.json()["json"]["name"]}    Robot
    Log    POST request with payload test passed

T04_03 Failing Test - Invalid URL
    Create Session    httpbin    ${BASE_URL}    verify=True
    Run Keyword And Expect Error    *    GET On Session    httpbin    /non_existent_endpoint    expected_status=200
    Log    This log statement should not be executed due to error

T04_04 Passing Test - Query Parameters
    Create Session    httpbin    ${BASE_URL}    verify=True
    ${params}=    Create Dictionary    ${PARAM_KEY}=${PARAM_VALUE}
    ${response}=    GET On Session    httpbin    ${ENDPOINT}    params=${params}
    Dictionary Should Contain Key    ${response.json()}    args
    Dictionary Should Contain Key    ${response.json()["args"]}    ${PARAM_KEY}
    Should Be Equal    ${response.json()["args"]["${PARAM_KEY}"]}    ${PARAM_VALUE}
    Log    Query parameters test passed

T04_05 Passing Test - Response Header Validation
    Create Session    httpbin    ${BASE_URL}    verify=True
    ${response}=    GET On Session    httpbin    ${ENDPOINT}
    Dictionary Should Contain Key    ${response.headers}    Content-Type
    Should Contain    ${response.headers['Content-Type']}    application/json
    Log    Response header validation test passed
