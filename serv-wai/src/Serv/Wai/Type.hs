{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE ExplicitForAll             #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}

-- Types describing a 'Server' which is generated by this package. Build
-- 'Server's, run them, convert them to 'Applications', work with the
-- 'Context' which they accumulate via routing.
module Serv.Wai.Type (

  -- * 'Server's

  -- | The 'Server' type is the core type generated by this module. It's
  -- essentially a 'StateT' monad storing a 'Context' accumulated over the
  -- routing process of the server.

    Server (..)
  , ServerResult (..)

  -- ** Basic 'Server's

  , returnServer
  , notFound
  , badRequest
  , methodNotAllowed
  , orElse

  -- ** Transforming 'Server's
  , mapServer

  -- ** Interpreting 'Server's
  , serverApplication
  , serverApplication'
  , serverApplication''

  -- *** Utilities
  , defaultRoutingErrorResponse


  -- * 'Context's

  -- | As a 'Server' runs it generates a 'Context' descrbing the routing
  -- and decoding/encoding process so far. The 'Context' provides valuable
  -- information aboue the 'Request' and also about how the implemtation of
  -- the server has examined the 'Request' so far.

  , Context (..)
  , makeContext

  -- * 'Contextual' monads

  -- | 'Server's are just monads within a server-like 'Context'---the
  -- 'Contextual' class abstracts out several operations which we expect to
  -- occur in such a context.
  , Contextual (..)

) where

import           Control.Monad.Morph
import           Control.Monad.State
import qualified Data.ByteString               as S
import qualified Data.ByteString.Lazy          as Sl
import qualified Data.CaseInsensitive          as CI
import           Data.IORef
import           Data.Map                      (Map)
import qualified Data.Map                      as Map
import           Data.Maybe                    (catMaybes)
import           Data.Set                      (Set)
import           Data.Singletons
import           Data.Singletons.TypeLits
import           Data.String
import           Data.Text                     (Text)
import qualified Data.Text.Encoding            as Text
import           Network.HTTP.Kinder.Header    (HeaderDecode, HeaderName,
                                                Sing (SContentType, SAllow),
                                                SomeHeaderName, headerDecodeBS,
                                                headerEncodePair, headerName,
                                                parseHeaderName)
import           Network.HTTP.Kinder.MediaType (AllMimeDecode,
                                                NegotiatedDecodeResult (..),
                                                negotiatedMimeDecode)
import           Network.HTTP.Kinder.Query     (QueryDecode (..),
                                                QueryKeyState (..))
import qualified Network.HTTP.Kinder.Status    as St
import           Network.HTTP.Kinder.Verb      (Verb, parseVerb)
import           Network.HTTP.Types.URI        (queryToQueryText)
import           Network.Wai
import           Serv.Wai.Error                (RoutingError)
import qualified Serv.Wai.Error                as Error

-- Server
-- ----------------------------------------------------------------------------

-- | A server executing in a given monad. We construct these from 'Api'
-- descriptions and corresponding 'Impl' descriptions for said 'Api's.
-- Ultimately, a 'Server', or at least a 'Server IO', is destined to be
-- transformed into a Wai 'Appliation', but 'Server' tracks around more
-- information useful for interpretation and route finding.
newtype Server m = Server { runServer :: StateT Context m ServerResult }

-- | Inject a monadic result directly into a 'Server'
returnServer :: Monad m => m ServerResult -> Server m
returnServer m = Server (lift m)

-- | Lift an effect transformation on to a Server
mapServer :: Monad m => (forall x . m x -> n x) -> Server m -> Server n
mapServer phi (Server act) = Server (hoist phi act)

-- | 'Server's form a semigroup trying each 'Server' in order and receiving
-- the leftmost one which does not end in an ignorable error.
--
-- Or, with less technical jargon, @m `orElse` n@ acts like @m@ except in the
-- case where @m@ returns an 'Error.ignorable' 'Error.Error' in which case control
-- flows on to @n@.
orElse :: Monad m => Server m -> Server m -> Server m
orElse sa sb = Server $ do
  (a, ctx) <- fork (runServer sa)
  case a of
    RoutingError e
      | Error.ignorable e -> runServer sb
      | otherwise -> restore ctx >> return a
    _ -> restore ctx >> return a

-- | A 'Server' which immediately fails with a 'Error.NotFound' error
notFound :: Monad m => Server m
notFound = Server (return (RoutingError Error.NotFound))

-- | A 'Server' which immediately fails with a 'Error.MethodNotAllowed'
-- error
methodNotAllowed :: Monad m => Set Verb -> Server m
methodNotAllowed verbs =
  Server (return (RoutingError (Error.MethodNotAllowed verbs)))

-- | A 'Server' which immediately fails with a 'Error.BadRequest' error
badRequest :: Monad m => Maybe String -> Server m
badRequest err = Server (return (RoutingError (Error.BadRequest err)))

-- | Converts a @'Server' 'IO'@ into a regular Wai 'Application' value.
serverApplication :: Server IO -> Application
serverApplication server = serverApplication' server (const id)

-- | Converts a @'Server' 'IO'@ into a regular Wai 'Application' value;
-- parameterized on a "response transformer" which allows a final
-- modification of the Wai response using information gathered from the
-- 'Context'. Useful, e.g., for writing final headers.
serverApplication' :: Server IO -> (Context -> Response -> Response) -> Application
serverApplication' server xform = do
  serverApplication'' server $ \ctx res ->
    case res of
      RoutingError err -> xform ctx (defaultRoutingErrorResponse err)
      WaiResponse resp -> xform ctx resp
      _ -> error "Recieved 'Application' value in 'serverApplication'' impl"

-- | Converts a @'Server' 'IO'@ into a regular Wai 'Application' value. The
-- most general of the @serverApplication*@ functions, parameterized on
-- a function interpreting the 'Context' and 'ServerResult' as a Wai
-- 'Response'. As an invariant, the interpreter will never see an
-- 'Application' 'ServerResult'---those are handled by this function.
serverApplication''
  :: Server IO
  -> (Context -> ServerResult -> Response)
  -> Application
serverApplication'' server xform request respond = do
  ctx0 <- makeContext request
  (val, ctx1) <- runStateT (runServer server) ctx0
  case val of
    Application app -> app ctx1 (ctxRequest ctx1) respond
    _ -> respond (xform ctx1 val)

-- | A straightforward way of transforming 'RoutingError' values to Wai
-- 'Response's. Used by default in 'serverApplication''.
defaultRoutingErrorResponse :: RoutingError -> Response
defaultRoutingErrorResponse err =
  case err of
    Error.NotFound ->
      responseLBS (St.httpStatus St.SNotFound) [] ""
    Error.BadRequest e -> do
      let errString = fromString (maybe "" id e)
      responseLBS (St.httpStatus St.SBadRequest) [] (fromString errString)
    Error.UnsupportedMediaType ->
      responseLBS (St.httpStatus St.SUnsupportedMediaType) [] ""
    Error.MethodNotAllowed verbs -> do
      responseLBS
        (St.httpStatus St.SMethodNotAllowed)
        (catMaybes [headerEncodePair SAllow verbs])
        ""

data ServerResult
  = RoutingError RoutingError
    -- ^ Routing errors arise when a routing attempt fails and, depending on the
    -- error, either we should recover and backtrack or resolve the entire response
    -- with that error.
  | WaiResponse Response
    -- ^ If the response is arising from the 'Server' computation itself it will
    -- be transformed automatically into a 'Wai.Response' value we can handle
    -- directly. These are opaque to routing, assumed successes.
  | Application (Context -> Application)
    -- ^ If the application demands an "upgrade" or ties into another server
    -- mechanism then routing at that location will return the (opaque)
    -- 'Application' to continue handling.

-- In Context
-- ----------------------------------------------------------------------------

class Contextual m where
  -- | Run a computation with the current state and return it without
  -- affecting ongoing state in this thread.
  fork :: m a -> m (a, Context)

  -- | Restore a 'Context'.
  restore :: Context -> m ()

  -- | Return the HTTP verb of the current context
  getVerb :: m (Maybe Verb)

  -- | Return 'True' if there are no further path segments
  endOfPath :: m Bool

  -- | Pops a path segment if there are any remaining
  popSegment :: m (Maybe Text)

  -- | Pops all remaining path segments
  popAllSegments :: m [Text]

  -- | Pulls the value of a header, attempting to parse it
  getHeader
    :: forall a (n :: HeaderName)
    . HeaderDecode n a => Sing n -> m (Either String a)

  -- | Asserts that we expect a header to take a given value; returns the
  -- validity of that expectation.
  expectHeader
    :: forall (n :: HeaderName)
    . Sing n -> Text -> m Bool

  -- | Pulls the value of a query parameter, attempting to parse it
  getQuery :: QueryDecode s a => Sing s -> m (Either String a)

  -- | Decodes the body according to the provided set of allowed content
  -- types
  getBody
    :: forall a (ts :: [*])
    . AllMimeDecode a ts => Sing ts -> m (Either String a)

-- | (internal) gets the raw header data
getHeaderRaw
  :: forall m (n :: HeaderName)
  . Monad m => Sing n -> StateT Context m (Maybe S.ByteString)
getHeaderRaw s = do
  hdrs <- gets ctxHeaders
  return $ Map.lookup (headerName s) hdrs

-- | (internal) declare that a header was accessed (and possibly that is
-- should take a certain value)
declareHeader
  :: forall m (n :: HeaderName)
  . Monad m => Sing n -> Maybe Text -> StateT Context m ()
declareHeader s val =
  modify $ \ctx ->
    ctx { ctxHeaderAccess =
            Map.insert
              (headerName s) val
              (ctxHeaderAccess ctx) }

-- | (internal) gets the raw query data
getQueryRaw
  :: forall m (n :: Symbol)
  . Monad m => Sing n -> StateT Context m (QueryKeyState Text)
getQueryRaw s = do
  qs <- gets ctxQuery
  let qKey = withKnownSymbol s (fromString (symbolVal s))
  return $ case Map.lookup qKey qs of
             Nothing -> QueryKeyAbsent
             Just Nothing -> QueryKeyPresent
             Just (Just val) -> QueryKeyValued val

-- | (internal) declare that a query key was accessed
declareQuery
  :: forall m (n :: Symbol)
  . Monad m => Sing n -> StateT Context m ()
declareQuery s = do
  let qKey = withKnownSymbol s (fromString (symbolVal s))
  modify $ \ctx ->
    ctx { ctxQueryAccess = qKey : ctxQueryAccess ctx }

instance Monad m => Contextual (StateT Context m) where
  fork m = StateT $ \ctx -> do
    (a, newCtx) <- runStateT m ctx
    return ((a, newCtx), ctx)

  restore = put

  getVerb = parseVerb <$> gets (requestMethod . ctxRequest)

  endOfPath = do
    path <- gets ctxPathZipper
    case path of
      (_, []) -> return True
      _ -> return False

  popSegment = do
    state $ \ctx ->
      case ctxPathZipper ctx of
        (_past, []) -> (Nothing, ctx)
        (past, seg:future) ->
          (Just seg, ctx { ctxPathZipper = (seg:past, future) })

  popAllSegments = do
    state $ \ctx ->
      case ctxPathZipper ctx of
        (past, fut) ->
          (fut, ctx { ctxPathZipper = (reverse fut ++ past, []) })

  getHeader s = do
    declareHeader s Nothing
    mayVal <- getHeaderRaw s
    return (headerDecodeBS s mayVal)

  expectHeader s expected = do
    declareHeader s (Just expected)
    mayVal <- fmap (fmap Text.decodeUtf8) (getHeaderRaw s)
    return (maybe False (== expected) mayVal)

  getQuery s = do
    declareQuery s
    qks <- getQueryRaw s
    return (queryDecode s qks)

  getBody ts = do
    eitCt <- getHeader SContentType
    body <- gets ctxBody
    return $ case negotiatedMimeDecode ts of
      Nothing -> Left "no acceptable content types"
      Just dec ->
        case dec (hush eitCt) body of
          NegotiatedDecode a -> Right a
          NegotiatedDecodeError err -> Left ("body decode error: " ++ err)
          DecodeNegotiationFailure mt -> Left ("could not negotiate: " ++ show mt)

hush :: Either e a -> Maybe a
hush (Left _) = Nothing
hush (Right a) = Just a

-- Context
-- ----------------------------------------------------------------------------

data Context =
  Context
  { ctxRequest      :: Request
    -- ^ The original 'Request' which this 'Context' was initiated from.
    -- The 'requestBody' here has been "frozen" so that even if it is
    -- accessed by the 'Server' it can be accessed again later without
    -- impact.
  , ctxPathZipper   :: ([Text], [Text])
    -- ^ The current location in the URI path. The 'Text' segments in the
    -- first part of the tuple are those which have already been
    -- consumed/visited (in reverse order) and those in the second part are
    -- those which have yet to be visited.
  , ctxHeaders      :: Map SomeHeaderName S.ByteString
    -- ^ An extraction of the headers in the 'Request'
  , ctxHeaderAccess :: Map SomeHeaderName (Maybe Text)
    -- ^ A 'Map' from headers which have been requested so far by the
    -- 'Server' to, possibly, the values that these headers are expected to
    -- take.
  , ctxQuery        :: Map Text (Maybe Text)
    -- ^ An extraction of the query parameters in the 'Request'
  , ctxQueryAccess  :: [Text]
    -- ^ A listing of query keys which have been accessed so far by the
    -- 'Server'


  , ctxBody         :: S.ByteString
    -- ^ The body of the 'Request', strictly read.
    --
    -- This is cached via 'strictRequestBody' so that we don't have to deal
    -- with multiple request body pulls affecting one another; this defeats
    -- partial and lazy body loading, BUT the style of API description
    -- we're talking about here isn't really amenable to that sort of thing
    -- anyway.
  }

-- | Construct a fresh context from a 'Request'. Fully captures the
-- (normally streamed) body so that repeated accesses in the server will
-- all see the same body (e.g., allows for pure, strict access to the body
-- later).
makeContext :: Request -> IO Context
makeContext theRequest = do
  theBody <- strictRequestBody theRequest
  -- We create a "frozen", strict version of the body and augment the request to
  -- always return it directly.
  ref <- newIORef (Sl.toStrict theBody)
  let headerSet =
        map (\(name, value) ->
              (parseHeaderName (ciBsToText name), value))
            (requestHeaders theRequest)
  let querySet = queryToQueryText (queryString theRequest)
  return Context { ctxRequest = theRequest { requestBody = readIORef ref }
                 , ctxPathZipper = ([], pathInfo theRequest)
                 , ctxHeaders = Map.fromList headerSet
                 , ctxQuery = Map.fromList querySet
                 , ctxHeaderAccess = Map.empty
                 , ctxQueryAccess = []
                 , ctxBody = Sl.toStrict theBody
                 }

-- | (internal) Converts a case insensitive bytestring to a case
-- insensitive text value.
ciBsToText :: CI.CI S.ByteString -> CI.CI Text
ciBsToText = CI.mk . Text.decodeUtf8 . CI.original
