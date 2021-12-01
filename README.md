# HTTP Webserver for kdb+

This repository provides a library for routing inbound HTTP URLs to defined kdb functions in the process.

Features include:

* Support for `GET` (`.z.ph`) and `POST` (`.z.pp`) requests
* API version support
  * Include automatically selecting the latest version
* URL parameter to function argument mapping
* kdb binary IPC responses (as `application/kdb-ipc`)
  * Client support in [kdb-common http.q](https://github.com/BuaBook/kdb-common/wiki/http.q#kdb-ipc-over-http)
* GZIP compressed responses (only with kdb+ 4.0 and later)
* Configurable to fallback to the original handler function if no matching webserver URL

## URL Template

By default, URLs are defined in the following form:

```
api/*library*/v*version*/*relative-url*
```

The 3 components - `library`, `version` and `relative-url` uniquely identify the URL to kdb function mapping.

When requesting a URL, `version` can be specified as `latest` and the webserver will automatically pick the function handler with the biggest version number.

## Configuration

The primary configuration table for the URL handling is `.websrv.endpoints` with the following columns:

| Column         | Type     | Description                                                                   |
| -------------- | -------- | ----------------------------------------------------------------------------- |
| `library`      | symbol   | A grouping of common functionality                                            |
| `version`      | float    | The API version                                                               |
| `relativeUrl`  | char[]   | The URL suffix                                                                |
| `targetFunc`   | symbol   | A symbol reference to the function that will be executed when the URL matches |
| `methods`      | symbol[] | The HTTP methods to support for this API                                      |
| `returnType`   | symbol   | The data format return type (key of `.h.ty`)                                  |
| `passHeaders`  | boolean  | If `true`, headers can be passed to the handler function                      |
| `enabled`      | boolean  | If `true`, the API will accept requests and route to the target function      |

The table is keyed by `library`, `version` and `relativeUrl`.

## Response Formats

The Webserver can return any configured content type as defined by `.h.ty` or extended by `.websrv.cfg.returnTypes`. However, for data responses, it is recommended to return a dictionary so the Webserver can enhance the response.

**NOTE**: That all error responses are returned with their content type set to `application/json`.

### Data Response - Success

```json
{
  "success": true,
  "url": original-url-no-params,
  "result": result-object
}
```

### Error

As mentioned above, all errors are returned with a content type of `application/json` and take the following form:

```json
{
    "success": false,
    "statusCode": "4xx" / "5xx",
    "url": original-url-no-params,
    "error": error-description
}
```

Some error responses also include:

* `detail`: Provides more detail as to the error that has occurred
* `handler`: The name of the handler function that has failed

## Error Codes

The webserver returns HTTP errors in the following conditions:

| HTTP Status | Error Message (`error`)      | Additional Description(s)                                              |
| ----------- | -----------------------------| ---------------------------------------------------------------------- |
| 404         | `Not Found`                  | Invalid URL (structure or unconfigured) with handler fallback disabled |
| 503         | `Service Unavailable`        | * Invalid URL (structure or unconfigured) with handler fallback enabled, but no handler<br/>* Valid URL but handler function is not defined |
| 405         | `Method Not Allowed`         | Current HTTP method is not supported for matched handler               |
| 406         | `Unsupported Client`         | Client does not support expected return type (via `Accept` header)     |
| 423         | `Locked`                     | The specified URL has been disabled by configuration                   |
| 422         | `Missing Parameter`          | The handler requires additional parameters to execute                  |
| 500         | `Handler Execution Failure`  | The handler function failed to execute                                 |

## Additional Configuration

The following additional configuration is available:

* `.websrv.cfg.prefix`
  * Default: `api`
  * The prefix required for a URL to be considered a valid webserver URL
* `.websrv.cfg.versionPrefix`
  * Default: `v`
  * The version prefix within the URL to be considered a valid webserver URL
* `.websrv.cfg.handlerBindMode`
  * Default: `all`
  * Defines which HTTP handlers should be overriden with the webserver handler
    * `none`: Do not automatically bind to any handler. Expect a manual call to `.websrv.handler`
    * `auto`: Bind to handlers that have a least one reference in the configuration table
    * `all`: Bind to all handlers regardless of the configuration table
* `.websrv.cfg.handlers`
  * A HTTP method to kdb function mapping. This will also include the original HTTP handler when the library is initialised
* `.websrv.cfg.deferToDefaultIfNoMatch`
  * Default: `0b`
  * When false, if there is no URL match an error is returned to client
  * When true, if there is no URL match, pass the URL to the original handler that was present prior to library initialisation
* `.websrv.cfg.defaultReturnType`
  * Default: `txt`
  * If no return type is specified by the handler configuration, use this value to lookup a content type in `.h.ty`
* `.websrv.cfg.returnTypes`
  * Default: `txt`, `json`, `kdbipc`
  * Supports additional content types (added to `.h.ty` on initialisation) and 'to string' conversion functions for all content types

## Examples

### Basic API

```q
/ Return the current time
q) .test.api:{ enlist[`time]!enlist .time.now[] };
q) `.websrv.endpoints upsert (`test; 1f; "api-test"; `.test.api; enlist `GET; `json; 0b; 1b);

/ Return all client headers
q) .test.apiHeaders:{[headers]  headers };
q) `.websrv.endpoints upsert (`test; 1f; "header-test"; `.test.apiHeaders; enlist `GET; `json; 1b; 1b);
```

### Server Side Web (PHP-Style)

```q
/ Build a HTML webpage with the current process PID
q) .test.html:{ .h.htc[`html;] .h.htc[`body;] .h.htc[`h2; "Process PID: ",string .z.i]; };
q) `.websrv.endpoints upsert (`html; 1f; "html"; `.test.html; enlist `GET; `html; 0b; 1b);
```

### Latest Version

```q
/ Multiple versions of the same API
q) .test.version1:{ enlist[`version]!enlist 1f };
q) .test.version2:{ enlist[`version]!enlist 2f };

q) `.websrv.endpoints upsert (`test; 1f; "version-test"; `.test.version1; enlist `GET; `json; 0b; 1b);
q) `.websrv.endpoints upsert (`test; 2f; "version-test"; `.test.version2; enlist `GET; `json; 0b; 1b);
```

```q
/ Client
q) .http.get["http://localhost:12345/api/test/v1.0/version-test"; ()!()][`body][`result]`version
1f
q) .http.get["http://localhost:12345/api/test/v2.0/version-test"; ()!()][`body][`result]`version
2f
q) .http.get["http://localhost:12345/api/test/vlatest/version-test"; ()!()][`body][`result]`version
2f
```