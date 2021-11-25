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

/ Primary configuration for the webserver
.websrv.endpoints:`library`version`relativeUrl xkey flip `library`version`relativeUrl`targetFunc`methods`returnType`passHeaders`enabled!"SF*S*SBB"$\:();
.websrv.endpoints[(`; 0Nf; "")]:(`; `symbol$(); `; 0b; 0b);


.websrv.init:{
    update origHandler:get each handler from `.websrv.cfg.handlers where .ns.isSet each handler;

    contentTypes:exec retType!contentType from .websrv.cfg.returnTypes where not null retType;

    .log.if.info "HTTP webserver supported content types: ",", " sv value contentTypes;
    .h.ty,:contentTypes;

    .websrv.i.bindToHandlers[];
 };


.websrv.handler:{[method; req]
    url:first "?" vs req 0;
    headers:req 1;

    urlInfo:.websrv.decodeUrl url;
    urlParams:.websrv.extractParamsFromUrl req 0;

    gzipReturn:(headers key[headers] first where lower[key headers] = `$"accept-encoding") in .http.cfg.gzipContentEncodings;

    .log.if.debug ("Inbound HTTP query [ Method: {} ] [ URL: {} ] [ GZIP: {} ]"; method; url; `no`yes gzipReturn);
    .log.if.trace (" [ URL Decoding: {} ] [ URL Parameters: {} ] [ URL Headers: {} ]"; urlInfo; urlParams; headers);

    if[not .websrv.cfg.prefix ~ urlInfo`prefix;
        :.websrv.i.buildResponse[400; 0b; `; `success`error`url!(0b; "Invalid URL"; url)];
    ];

    match:.websrv.endpoints urlInfo`library`version`relativeUrl;

    if[.type.isInfinite urlInfo`version;
        latest:select from .websrv.endpoints where version = (max; version) fby ([] library; relativeUrl);
        match:latest urlInfo`library`version`relativeUrl;
    ];

    if[null match`targetFunc;
        if[not .websrv.cfg.deferToDefaultIfNoMatch;
            :.websrv.i.buildResponse[404; 0b; `; `success`error`url!(0b; "Invalid URL"; url)];
        ];

        origHandler:.websrv.cfg.handlers[method; `origHandler];

        if[null origHandler;
            :.websrv.i.buildResponse[404; 0b; `; `success`error`detail`url!(0b; "Invalid URL"; "No default handler to process"; url)];
        ];

        .log.if.debug "Deferring non-matched HTTP request to the default HTTP handler [ URL: ",req[0]," ]";

        :origHandler req;
    ];

    returnType:match`returnType;

    .log.if.trace "HTTP URL match [ URL: ",url," ] [ Function: ",string[match`targetFunc]," ] [ Return Type: ",string[returnType]," ]";

    if[not match`enabled;
        :.websrv.i.buildResponse[404; 0b; `; `success`error`url!(0b; "URL disabled"; url)];
    ];

    if[match`passHeaders;
        if[`headers in key urlParams;
            .log.if.warn "URL parameter already contains a 'headers' key, which will be overwritten to pass headers to handler function";
        ];

        urlParams[`headers]:headers;
    ];

    if[not .ns.isSet match`targetFunc;
        .log.if.error "Specified URL handler function not defined [ URL: ",url," ] [ Target Func: ",string[match`targetFunc]," ]";
        :.websrv.i.buildResponse[404; 0b; returnType; `success`error`handler`url!(0b; "Invalid URL - Handler Not Defined"; string match`targetFunc; url)];
    ];


    funcRes:.ns.protectedExecute[`.ns.executeFuncWithDict; (match`targetFunc; urlParams)];

    if[.ns.const.pExecFailure ~ first funcRes;
        error:funcRes`errorMsg;

        $[error like "MissingFunctionArgumentException*";
            :.websrv.i.buildResponse[406; 0b; returnType; `error`detail`url!("Missing Parameter"; error; url)];
        / else
            :.websrv.i.buildResponse[500; 0b; returnType; `error`detail`url`handler!("Handler Execution Failed"; error; url; match`targetFunc)]
        ];
    ];

    return:`success`url`result!(1b; url; funcRes);

    :.websrv.i.buildResponse[200; gzipReturn; returnType; return];
 };

/ Extracts all parameters ('&' separated key=value pairs after the '?') from the URL
/  @param url (String) The URL to extract the parameters from
/  @returns (Dict) The parameters. All keys are cast to symbol and all values are kept as strings
.websrv.extractParamsFromUrl:{[url]
    / If the URL is empty, there are no parameters or "?" is the first character (kdb-query string for '.z.ph'), do not attempt to parse
    $[0 = count url;
        :()!();
    not "?" in url;
        :()!();
    "?" = first url
        :()!()
    ];

    paramStr:last "?" vs url;
    paramVals:"&" vs paramStr;

    paramDict:.h.uh each (!). "S*" $' flip "=" vs/: paramVals;
    :paramDict;
 };

.websrv.decodeUrl:{[url]
    urlSplit:"/" vs url;

    plv:`prefix`library`version!3#urlSplit;
    plv[`library]:"S"$plv`library;
    plv[`version]:plv[`version] except .websrv.cfg.versionPrefix;
    plv[`version]:"F"$?["latest" ~ plv`version; "inf"; plv`version];

    rel:enlist[`relativeUrl]!enlist "/" sv 3_ urlSplit;

    :plv,rel;
 };


.websrv.i.bindToHandlers:{
    if[`none = .websrv.cfg.handlerBindMode;
        .log.if.info "Not binding to any web handlers in current process as per configuration";
        :(::);
    ];

    toBind:`symbol$();

    if[`auto = .websrv.cfg.handlerBindMode;
        handlers:distinct raze exec methods from .websrv.endpoints where not null targetFunc;

        if[not all handlers in key .websrv.cfg.handlers;
            .log.if.fatal "One or more endpoints have an invalid HTTP method specified";
            .log.if.fatal " Only ",.convert.listToString[key .websrv.cfg.handlers]," supported";
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

.websrv.i.buildResponse:{[httpStatus; gzip; retType; return]
    retType:.websrv.cfg.defaultReturnType ^ retType;

    statusStr:string[httpStatus]," ",.http.status httpStatus;
    returnStr:.websrv.cfg.returnTypes[retType][`convertFunc] return;

    httpResponse:.h.hnz[statusStr; gzip; retType; returnStr];

    .log.if.trace ("HTTP response [ Status: {} ] [ GZIP: {} ] [ Returns: {} ] [ Length: {} bytes ]"; statusStr;`no`yes gzip; retType; count httpResponse);

    :httpResponse;
 };
