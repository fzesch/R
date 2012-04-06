.TraceWithMethods <- function(what, tracer = NULL, exit = NULL, at = numeric(), print = TRUE, signature = NULL, where = .GlobalEnv) {
    whereF <- NULL
    def <- NULL
    if(is.function(what)) {
        def <- what
        fname <- substitute(what)
        if(is.name(fname))
            what <- as.character(fname)
        else if(is.call(fname) && identical(fname[[1]], as.name("::"))) {
            whereF <-as.character(fname[[2]])
            require(whereF, character.only = TRUE)
            whereF <- as.environment(paste("package", whereF, sep=":"))
            what <- as.character(fname[[3]])
        }
        else if(is.call(fname) && identical(fname[[1]], as.name(":::"))) {
            whereF <- loadNamespace(as.character(fname[[2]]))
            what <- as.character(fname[[3]])
        }
        else
            stop("Argument what should be the name of a function")
    }
    else {
        what <- as.character(what)
        if(length(what) != 1) {
            for(f in what) {
                if(nargs() == 1)
                    trace(f)
                else
                    trace(f, tracer, exit, at, print, signature)
            }
            return(what)
        }
    }
    if(nargs() == 1)
        return(.primTrace(what)) # for back compatibility
    if(is.null(whereF)) {
        allWhere <- findFunction(what, where = where)
        if(length(allWhere)==0)
            stop("No function definition for \"", what, "\" found")
        whereF <- as.environment(allWhere[[1]])
    }
    if(is.null(def))
        def <- getFunction(what, where = whereF)
    if(!is.null(signature)) {
        whereM <- findMethod(what, signature, where = where)
        if(length(whereM) == 0) {
            def <- selectMethod(what, signature)
            whereM <- whereF
        }
        else {
            whereM <- as.environment(whereM[[1]])
            def <- getMethod(what, signature, where = whereM)
        }
    }
    fBody <- body(def)
    if(!is.null(exit)) {
        if(is.function(exit)) {
            tname <- substitute(exit)
            if(is.name(tname))
                exit <- tname
            exit <- substitute(TRACE(), list(TRACE=exit))
        }
    }
    if(!is.null(tracer)) {
        if(is.function(tracer)) {
            tname <- substitute(tracer)
            if(is.name(tname))
                tracer <- tname
            tracer <- substitute(TRACE(), list(TRACE=tracer))
        }
    }
    ## undo any current tracing
    def <- .untracedFunction(def)
    newFun <- new(.traceClassName(class(def)), def = def, tracer = tracer, exit = exit, at = at
                  , print = print)
    if(is.null(signature)) {
        if(bindingIsLocked(what, whereF))
            .assignOverBinding(what, newFun, whereF)
        else
            assign(what, newFun, whereF)
    }
    else {
        if(bindingIsLocked(what, whereM))
            .setMethodOverBinding(what, signature, newFun, whereM)
        else
            setMethod(what, signature, newFun, where = whereM)
    }
    what
}

.makeTracedFunction <- function(def, tracer, exit, at, print) {
    switch(typeof(def),
           builtin = , special = {
               fBody <- substitute({.prim <- DEF; .prim(...)},
                                   list(DEF = def))
               def <- eval(function(...)NULL)
               environment(def) <-  .GlobalEnv
               warning("making a traced version of a primitive; arguments will be treated as \"...\"")
           }, {
               if(is(def, "traceable"))
                  def <- .untracedFunction(def)
               fBody <- body(def)
              }
           )
    if(length(at) > 0) {
        if(is.null(tracer))
            stop("can't use \"at\" argument without a trace expression")
        else if(class(fBody) != "{")
            stop("can't use \"at\" argument unless the function body has the form { ... }")
        for(i in at) {
            if(print)
                expri <- substitute({if(tracingState()){methods::.doTracePrint(MSG); TRACE}; EXPR},
                            list(TRACE = tracer, MSG = paste("step",i), EXPR = fBody[[i]]))
            else
                expri <- substitute({if(tracingState())TRACE; EXPR},
                            list(TRACE=tracer, EXPR = fBody[[i]]))
            fBody[[i]] <- expri
        }
    }
    else if(!is.null(tracer)){
            if(print)
                fBody <- substitute({if(tracingState()){methods::.doTracePrint(MSG); TRACE}; EXPR},
                            list(TRACE = tracer, MSG = paste("on entry"), EXPR = fBody))
            else
                fBody <- substitute({if(tracingState())TRACE; EXPR},
                            list(TRACE=tracer, EXPR = fBody))
    }
    if(!is.null(exit)) {
        if(print)
            exit <- substitute(if(tracingState()){methods::.doTracePrint(MSG); EXPR},
                            list(EXPR = exit, MSG = paste("on exit")))
        else
            exit <- substitute(if(tracingState())EXPR,
                            list(EXPR = exit, MSG = paste("on exit")))
        fBody <- substitute({on.exit(TRACE); BODY},
                            list(TRACE=exit, BODY=fBody))
    }
    body(def, envir = environment(def)) <- fBody
    def
}

.untracedFunction <- function(f, what, where, signature = NULL) {
    while(is(f, "traceable"))
        f <- f@original
    if(!missing(what)) {
        if(is.null(signature)) {
            if(bindingIsLocked(what, where))
                .assignOverBinding(what, f, where)
            else
                assign(what, f, where)
        }
        else {
        if(bindingIsLocked(what, where))
            .setMethodOverBinding(what, signature, f, where)
        else
            setMethod(what, signature, f, where = where)
        }
    }
    f
}


.InitTraceFunctions <- function(envir)  {
    setClass("traceable", representation(original = "PossibleMethod"), contains = "VIRTUAL",
             where = envir); clList <- "traceable"
    ## create the traceable classes
    for(cl in c("function", "MethodDefinition", "MethodWithNext", "genericFunction",
                "standardGeneric", "nonstandardGeneric", "groupGenericFunction",
                "derivedDefaultMethod")) {
        setClass(.traceClassName(cl),
                 representation(cl, "traceable"), where = envir)
        clList <- c(clList, .traceClassName(cl))
    }
    assign(".SealedClasses", c(get(".SealedClasses", envir), clList), envir);
    setMethod("initialize", "traceable",
              function(.Object, def, tracer, exit, at, print) {
                  oldClass <- class(def)
                  if(isClass(oldClass) && length(getClass(oldClass)@slots) > 0)
                      as(.Object, oldClass) <- def # to get other slots in def
                  .Object@original <- def
                  if(!is.null(elNamed(getSlots(getClass(class(def))), ".Data")))
                      def <- def@.Data
                  .Object@.Data <- .makeTracedFunction(def, tracer, exit, at, print)
                  .Object
              }, where = envir)
    if(!isGeneric("show", envir))
        setGeneric("show", where = envir)
    setMethod("show", "traceable", function(object) {
        message("Object of class \"", class(object), "\"")
        show(object@original)
        cat("\n## (to see the tracing code, look at body(object))\n")
    }, where = envir)
}

.doTracePrint <- function(msg = "") {
    call <- deparse(sys.call(sys.parent(1)))
    if(length(call)>1)
        call <- paste(call[[1]], "....")
    cat("Tracing", call, msg, "\n")
}

.traceClassName <- function(className) {
    paste(className, "WithTrace", sep="")
}

trySilent <- function(expr) {
    call <- sys.call()
    call[[1]] <- quote(try)
    opt1 <- options(show.error.messages = FALSE)
    opt2 <- options(error = quote(empty.dump()))
    ## following is a workaround of a bug in options that does not
    ## acknowledge NULL as an options value => delete this element.
    if(is.null(opt1[[1]]))
      on.exit({options(show.error.messages = TRUE); options(opt2)})
    else
      on.exit({options(opt1); options(opt2)})
    eval.parent(call)
}

.assignOverBinding <- function(what, value, where, warn = TRUE) {
    pname <- getPackageName(where)
    if(warn)
        warning("Assigning over the binding of symbol \"", what,
                "\" in environment/package \"", pname, "\"")
    warnOpt <- options(warn= -1) # kill the obsolete warnign from R_LockBinding
    on.exit(options(warnOpt))
    if(is.function(value)) {
        ## assign in the namespace for the function as well
        fenv <- environment(value)
        if(!identical(fenv, where) && exists(what, envir = fenv, inherits = FALSE #?
                                             ) && bindingIsLocked(what, fenv)) {
            unlockBinding(what, fenv)
            assign(what, value, fenv)
            lockBinding(what, fenv)
        }
    }
    unlockBinding(what, where)
    assign(what, value, where)
    lockBinding(what, where)
}

.setMethodOverBinding <- function(what, signature, method, where, warn = TRUE) {
    if(warn)
        warning("Setting a method over the binding of symbol \"", what,
                "\" in environment/package \"", getPackageName(where), "\"")
    if(exists(what, envir = where, inherits = FALSE)) {
        fdef <- get(what, envir = where)
        hasFunction <- is(fdef, "genericFunction")
    }
    else
        hasFunction <- FALSE
    if(hasFunction) {
        ## find the generic in the corresponding namespace
        metaName <- mlistMetaName(fdef)
        where2 <- findFunction(what, where = environment(fdef))[[1]] # must find it?
        unlockBinding(metaName, where)
        unlockBinding(what, where)
        setMethod(what, signature, method, where = where)
        lockBinding(what, where)
        lockBinding(metaName, where)
        ## assign in the package namespace as well
        unlockBinding(what, where2)
        unlockBinding(metaName, where2) # FIXME:  look for sig. ?
        setMethod(what, signature, method, where = where2)
        lockBinding(metaName, where2)
        lockBinding(what, where2)
    }
    else {
        metaName <- mlistMetaName(what)
        unlockBinding(metaName, where)
        setMethod(what, signature, method, where = where)
        lockBinding(metaName, where)
    }
}