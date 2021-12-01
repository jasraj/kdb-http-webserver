// HTTP WebServer
// Copyright (c) 2021 Jaskirat Rajasansir

.require.lib each `type`convert`ns`http;

// By default the URLs will be formed as:
//   api/*library*/v*version*/*relative-url*

/ The URL prefix for all API calls handled by this library
.websrv.cfg.prefix:"api";

/ The version prefix for all API calls handled by this library
.websrv.cfg.versionPrefix:"v";

/ How the library should bind to the kdb+ web handlers in the current process:
/  - none: Do not bind to any handlers. Manually call .websrv.handler
/  - auto: Bind to handlers that have a least one reference in '.websrv.endpoints'
/  - all: Bind to all available handlers regardless of definitions in '.websrv.endpoints'
.websrv.cfg.handlerBindMode:`all;

/ The handler names and kdb+ functions to override. The original handler function will be copied to fallback to it if required (as
/ set by '.websrv.cfg.deferToDefaultIfNoMatch')
.websrv.cfg.handlers:`method xkey flip `method`handler`origHandler!"SS*"$\:();
.websrv.cfg.handlers[`GET]: (`.z.ph; ::);
.websrv.cfg.handlers[`POST]:(`.z.pp; ::);

/ If true, the library will defer the inbound HTTP call to the default .z.ph / .z.pp if the inbound URL does not
/ match any of the configured endpoints. If false, the library will return a 404 error if the inbound URL does not match
.websrv.cfg.deferToDefaultIfNoMatch:0b;

/ If no return type is specified for the URL, defaults to 'text/plain'
.websrv.cfg.defaultReturnType:`txt;

/ Supported return types and return object conversion function for each type
.websrv.cfg.returnTypes:`retType xkey flip `retType`contentType`convertFunc!"S**"$\:();
.websrv.cfg.returnTypes[`]:         (""; (::));
.websrv.cfg.returnTypes[`txt]:      ("text/plain";          .type.ensureString);
.websrv.cfg.returnTypes[`json]:     ("application/json";    .j.j);
.websrv.cfg.returnTypes[`kdbipc]:   ("application/kdb-ipc"; { raze string -18!x });

/ The content types that are "data" responses, such that a dictionary repsonse is sensible
.websrv.cfg.dataContentTypes:`json`kdbipc;


/ Primary configuration for the webserver
.websrv.endpoints:`library`version`relativeUrl xkey flip `library`version`relativeUrl`targetFunc`methods`returnType`passHeaders`enabled!"SF*S*SBB"$\:();
.websrv.endpoints[(`; 0Nf; "")]:(`; `symbol$(); `; 0b; 0b);

/ Headers that should be extracted from every request
.websrv.requestExtractHeaders:`accept`acceptEncoding!`$("accept"; "accept-encoding");

/ The value within a 'Accept' header that signals any content type is supported
.websrv.acceptHeaderAny:"*/*";


.websrv.init:{
    update origHandler:get each handler from `.websrv.cfg.handlers where .ns.isSet each handler;

    contentTypes:exec retType!contentType from .websrv.cfg.returnTypes where not null retType;

    .log.if.info ("HTTP webserver supported content types: {}"; value contentTypes);
    .h.ty,:contentTypes;

    .websrv.i.bindToHandlers[];
 };


/ Webserver handler
/  @param method (Symbol) The HTTP method that the handler has been called for
/  @param req (List) The 2-element list passed from the kdb HTTP GET or POST handlers
.websrv.handler:{[method; req]
    url:first "?" vs req 0;
    headers:req 1;

    urlInfo:.websrv.i.decodeUrl url;
    urlParams:.websrv.i.extractParamsFromUrl req 0;

    headerExtract:key[.websrv.requestExtractHeaders]!headers key[headers] first each where each value[.websrv.requestExtractHeaders]=\: lower key headers;
    headerExtract:"," vs/: headerExtract;

    match:.websrv.endpoints urlInfo`library`version`relativeUrl;

    if[.type.isInfinite urlInfo`version;
        latest:select from .websrv.endpoints where version = (max; version) fby ([] library; relativeUrl);
        match:latest urlInfo`library`version`relativeUrl;
    ];


    .log.if.debug ("Inbound HTTP {} query [ URL: {} ] [ Valid: {} ] [ Match: {} ]"; method; url; `no`yes urlInfo`valid; `yes`no null match`targetFunc);
    .log.if.trace (" [ URL Parameters: {} ] [ Headers: {} ]"; urlParams; headers);


    if[not[urlInfo`valid] | null match`targetFunc;
        if[not .websrv.cfg.deferToDefaultIfNoMatch;
            :.websrv.i.buildErrorResponse[404; ""; ""; url; ()!()];
        ];

        origHandler:.websrv.cfg.handlers[method; `origHandler];

        if[null origHandler;
            :.websrv.i.buildErrorResponse[503; ""; "Fallback handler is not defined"; url; ()!()];
        ];

        .log.if.debug ("Deferring non-matched HTTP request to the fallback HTTP handler [ URL: {} ] "; req 0);

        :origHandler req;
    ];

    if[not method in match`methods;
        :.websrv.i.buildErrorResponse[405; ""; ""; url; ()!()];
    ];

    / Ignore any quality factor weighting (;q=) - see https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Accept
    clientAccepts:first each ";" vs/: headerExtract`accept;
    expectedReturn:.h.ty match`returnType;

    if[not any (expectedReturn; .websrv.acceptHeaderAny) in clientAccepts;
        :.websrv.i.buildErrorResponse[406; "Unsupported Client"; "Unsupported client does not support: ",expectedReturn; url; ()!()];
    ];

    if[not .ns.isSet match`targetFunc;
        .log.if.error ("Specified URL handler function not defined [ URL: {} ] [ Target Func: {} ]"; url; match`targetFunc);
        :.websrv.i.buildErrorResponse[503; ""; "URL handler not defined"; url; enlist[`handler]!enlist match`targetFunc];
    ];

    if[not match`enabled;
        :.websrv.i.buildErrorResponse[423; ""; "URL handler is disabled"; url; ()!()];
    ];


    .log.if.trace ("Webserver processing URL [ URL: {} ] [ Function: {} ] [ Return Type: {} ]"; url; match`targetFunc; match`returnType);

    if[match`passHeaders;
        urlParams[`headers]:headers;
    ];

    funcRes:.ns.protectedExecute[`.ns.executeFuncWithDict; (match`targetFunc; urlParams)];

    if[.ns.const.pExecFailure ~ first funcRes;
        error:funcRes`errorMsg;

        $[error like "MissingFunctionArgumentException*";
            :.websrv.i.buildErrorResponse[422; "Missing Parameter"; error; url; ()!()];
        / else
            :.websrv.i.buildErrorResponse[500; "Handler Execution Failure"; error; url; enlist[`handler]!enlist match`targetFunc]
        ];
    ];

    return:`url`result!(url; funcRes);

    gzip:any .http.cfg.gzipContentEncodings in headerExtract`acceptEncoding;

    :.websrv.i.buildResponse[200; gzip; match`returnType; return];
 };

/ Extracts all parameters ('&' separated key=value pairs after the '?') from the URL and unescapes them
/  @param url (String) The URL to extract the parameters from
/  @returns (Dict) The parameters. All keys are cast to symbol and all values are kept as strings
/  @see .h.uh
.websrv.i.extractParamsFromUrl:{[url]
    / If the URL is empty, there are no parameters or "?" is the first character (kdb-query string for '.z.ph'), do not attempt to parse
    $[0 = count url;
        :()!();
    not "?" in url;
        :()!();
    "?" = first url;
        :()!()
    ];

    paramStr:last "?" vs url;
    paramVals:"&" vs paramStr;

    paramDict:.h.uh each (!). "S*" $' flip "=" vs/: paramVals;
    :paramDict;
 };

/ Validates and decodes the inbound URL
/  @param url (String) The URL to decode
/  @returns (Dict) The parsed elements of the URL. NOTE: If 'valid' is false, the URL will be not routed to any matching configuration
.websrv.i.decodeUrl:{[url]
    urlSplit:"/" vs url;

    plv:`prefix`library`rawVersion!3#urlSplit;
    plv[`library]:"S"$plv`library;
    plv[`version]:plv[`rawVersion] except .websrv.cfg.versionPrefix;
    plv[`version]:"F"$?["latest" ~ plv`version; "inf"; plv`version];

    plv[`valid]:all (.websrv.cfg.prefix ~ plv`prefix; plv[`rawVersion] like .websrv.cfg.versionPrefix,"*"; 0 < plv`version);

    rel:enlist[`relativeUrl]!enlist "/" sv 3_ urlSplit;

    :(enlist[`rawVersion]_ plv),rel;
 };

/ Binds the primary '.websrv.handler' function the kdb+ HTTP handler methods based on the specified configuration
/  @throws InvalidHttpMethodForEndpointException If any configured endpoint has an invalid HTTP method specified
/  @see .websrv.cfg.handlerBindMode
/  @see .websrv.cfg.handlers
.websrv.i.bindToHandlers:{
    if[`none = .websrv.cfg.handlerBindMode;
        .log.if.info "Not binding to any web handlers in current process as per configuration";
        :(::);
    ];

    toBind:`symbol$();

    if[`auto = .websrv.cfg.handlerBindMode;
        handlers:distinct raze exec methods from .websrv.endpoints where not null targetFunc;

        if[not all handlers in key .websrv.cfg.handlers;
            .log.if.fatal ("One or more endpoints have an invalid HTTP method specified. Only {} supported"; .websrv.cfg.handlers);
            '"InvalidHttpMethodForEndpointException";
        ];

        toBind:handlers;
    ];

    if[`all = .websrv.cfg.handlerBindMode;
        .log.if.info "Binding to all web handlers in current process as per configuration";
        toBind:exec method from .websrv.cfg.handlers;
    ];


    if[0 = count toBind;
        .log.if.debug ("No web handlers to bind to based on current configuration [ Config: {} ]"; .websrv.cfg.handlerBindMode);
        :(::);
    ];

    kdbFuncs:(.websrv.cfg.handlers@/:toBind)`handler;

    .log.if.info ("Binding HTTP web server library to web handlers: {}"; .convert.listToString kdbFuncs);

    (set) ./: kdbFuncs,'.websrv.handler @/: toBind;
 };

/ Builds the HTTP response to return to the client
/  @param httpStatus (Integer) The HTTP status of the response
/  @param gzip (Boolean) If true, compress the response
/  @param retType (Symbol) The content type of the response (key of .h.ty)
/  @param return () The object to return to the client
/  @returns (String) The HTTP response to be returned to the client
/  @see .websrv.cfg.defaultReturnType
/  @see .websrv.cfg.dataContentTypes
/  @see .http.status
.websrv.i.buildResponse:{[httpStatus; gzip; retType; return]
    retType:.websrv.cfg.defaultReturnType ^ retType;

    if[not retType in .websrv.cfg.dataContentTypes;
        if[.type.isDict return;
            return:return`result;
        ];
    ];

    if[.type.isDict return;
        return:(`success`statusCode!(`success = .http.responseTypes httpStatus; httpStatus)),return;
    ];

    statusStr:string[httpStatus]," ",.http.status httpStatus;
    returnStr:.websrv.cfg.returnTypes[retType][`convertFunc] return;

    httpResponse:.h.hnz[statusStr; gzip; retType; returnStr];

    .log.if.trace ("HTTP response [ Status: {} ] [ GZIP: {} ] [ Returns: {} ] [ Length: {} bytes ]"; statusStr;`no`yes gzip; retType; count httpResponse);

    :httpResponse;
 };

/ Builds a HTTP error response to return to the client
/ NOTE: Error responses are always returned as 'application/json' without checking if the client can accept it
/  @param httpStatus (Integer) The HTTP status of the response. Must be in the 4xx or 5xx range
/  @param error (String) Short description of the error that has occurred. If this is empty, it will populate with the default HTTP status
/  @param errorDetail (String) Any additional string error detail to be returned
/  @param additional (Dict) Any other dictionary elements to return to the user
/  @throws InvalidHttpStatusCodeForErrorException If the specified HTTP status code is not in the 4xx or 5xx range
/  @see .http.responseTypes
/  @see .http.status
/  @see .websrv.i.buildResponse
.websrv.i.buildErrorResponse:{[httpStatus; error; errorDetail; url; additional]
    if[not .http.responseTypes[httpStatus] in `clientError`serverError;
        '"InvalidHttpStatusCodeForErrorException";
    ];

    if[0 = count error;
        error:.http.status httpStatus;
    ];

    errorDict:`error`url!(error; url);

    if[0 < count errorDetail;
        errorDict[`detail]:errorDetail;
    ];

    if[0 < count additional;
        errorDict:errorDict,additional;
    ];

    :.websrv.i.buildResponse[httpStatus; 0b; `json; errorDict];
 };
