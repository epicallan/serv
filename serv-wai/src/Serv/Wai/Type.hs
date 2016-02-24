{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE ExplicitForAll             #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}

module Serv.Wai.Type where

import           Control.Monad.IO.Class
import           Control.Monad.Morph
import           Control.Monad.Reader
import           Control.Monad.State
import qualified Data.ByteString            as S
import qualified Data.ByteString.Lazy       as Sl
import qualified Data.CaseInsensitive       as CI
import           Data.IORef
import           Data.Map                   (Map)
import qualified Data.Map                   as Map
import           Data.Maybe                 (catMaybes)
import           Data.Set                   (Set)
import           Data.Singletons
import           Data.Singletons.TypeLits
import           Data.String
import           Data.Text                  (Text)
import qualified Data.Text.Encoding         as Text
import           Network.HTTP.Kinder.Header (HeaderDecode, HeaderName,
                                             Sing (SAllow), SomeHeaderName,
                                             headerDecodeBS, headerEncodePair,
                                             headerName, parseHeaderName)
import           Network.HTTP.Kinder.Query  (QueryDecode (..),
                                             QueryKeyState (..))
import qualified Network.HTTP.Kinder.Status as St
import           Network.HTTP.Kinder.Verb   (Verb, parseVerb)
import           Network.HTTP.Types.URI     (queryToQueryText)
import           Network.Wai
import           Serv.Wai.Error             (RoutingError)
import qualified Serv.Wai.Error             as Error

-- Server
-- ----------------------------------------------------------------------------

-- | A server executing in a given monad. We construct these from 'Api'
-- descriptions and corresponding 'Impl' descriptions for said 'Api's.
-- Ultimately, a 'Server', or at least a 'Server IO', is destined to be
-- transformed into a Wai 'Appliation', but 'Server' tracks around more
-- information useful for interpretation and route finding.
newtype Server m = Server { runServer :: InContext m ServerResult }

-- | Lift an effect transformation on to a Server
mapServer :: Monad m => (forall x . m x -> n x) -> Server m -> Server n
mapServer phi (Server act) = Server (hoist phi act)

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
  (val, ctx1) <- runStateT (runInContext (runServer server)) ctx0
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
    :: forall a (n :: HeaderName)
    . Sing n -> Text -> m Bool

  -- | Pulls the value of a query parameter, attempting to parse it
  getQuery :: QueryDecode s a => Sing s -> m (Either String a)

newtype InContext m a
  = InContext { runInContext :: StateT Context m a }
  deriving (Functor, Applicative, Monad, MonadTrans, MonadState Context, MonadIO, MFunctor)

instance Monad m => MonadReader Context (InContext m) where
  ask = get
  local f m = do
    (a, _ctx) <- fork (modify f >> m)
    return a

-- | (internal) gets the raw header data
getHeaderRaw
  :: forall m a (n :: HeaderName)
  . Monad m => Sing n -> InContext m (Maybe S.ByteString)
getHeaderRaw sing = do
  hdrs <- asks ctxHeaders
  return $ Map.lookup (headerName sing) hdrs

-- | (internal) declare that a header was accessed (and possibly that is
-- should take a certain value)
declareHeader
  :: forall m a (n :: HeaderName)
  . Monad m => Sing n -> Maybe Text -> InContext m ()
declareHeader sing val =
  modify $ \ctx ->
    ctx { ctxHeaderAccess =
            Map.insert
              (headerName sing) val
              (ctxHeaderAccess ctx) }

-- | (internal) gets the raw query data
getQueryRaw
  :: forall m a (n :: Symbol)
  . Monad m => Sing n -> InContext m (QueryKeyState Text)
getQueryRaw sing = do
  qs <- asks ctxQuery
  let qKey = withKnownSymbol sing (fromString (symbolVal sing))
  return $ case Map.lookup qKey qs of
             Nothing -> QueryKeyAbsent
             Just Nothing -> QueryKeyPresent
             Just (Just val) -> QueryKeyValued val

-- | (internal) declare that a query key was accessed
declareQuery
  :: forall m a (n :: Symbol)
  . Monad m => Sing n -> InContext m ()
declareQuery sing = do
  let qKey = withKnownSymbol sing (fromString (symbolVal sing))
  modify $ \ctx ->
    ctx { ctxQueryAccess = qKey : ctxQueryAccess ctx }

instance Monad m => Contextual (InContext m) where
  fork (InContext m) = do
    ctx <- ask
    (a, newCtx) <- lift (runStateT m ctx)
    return (a, newCtx)

  getVerb = parseVerb <$> asks (requestMethod . ctxRequest)

  endOfPath = do
    path <- asks ctxPathZipper
    case path of
      (_, []) -> return True
      _ -> return False

  popSegment = do
    state $ \ctx ->
      case ctxPathZipper ctx of
        (past, []) -> (Nothing, ctx)
        (past, seg:future) ->
          (Just seg, ctx { ctxPathZipper = (seg:past, future) })

  popAllSegments = do
    state $ \ctx ->
      case ctxPathZipper ctx of
        (past, fut) ->
          (fut, ctx { ctxPathZipper = (reverse fut ++ past, []) })

  getHeader sing = do
    declareHeader sing Nothing
    mayVal <- getHeaderRaw sing
    return (headerDecodeBS sing mayVal)

  expectHeader sing expected = do
    declareHeader sing (Just expected)
    mayVal <- fmap (fmap Text.decodeUtf8) (getHeaderRaw sing)
    return (maybe False (== expected) mayVal)

  getQuery sing = do
    declareQuery sing
    qks <- getQueryRaw sing
    return (queryDecode sing qks)

-- Context
-- ----------------------------------------------------------------------------

data Context =
  Context
  { ctxRequest      :: Request
  , ctxPathZipper   :: ([Text], [Text])
  , ctxHeaders      :: Map SomeHeaderName S.ByteString
  , ctxHeaderAccess :: Map SomeHeaderName (Maybe Text)
  , ctxQuery        :: Map Text (Maybe Text)
  , ctxQueryAccess  :: [Text]

    -- cached via strictRequestBody so that we don't have to deal with multiple
    -- request body pulls affecting one another; this defeats partial and lazy body
    -- loading, BUT the style of API description we're talking about here isn't really
    -- amenable to that sort of thing anyway.
    --
    -- also note that we really need to compute this using Lazy IO; otherwise,
    -- we'll have to be handling the partial request/respond dance from the get-go.

  , ctxBody         :: S.ByteString
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
