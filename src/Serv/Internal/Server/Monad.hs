{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RankNTypes                 #-}

module Serv.Internal.Server.Monad where

import           Control.Monad.IO.Class
import           Control.Monad.Reader
import           Control.Monad.State.Strict
import           Control.Monad.Trans
import           Data.Text                    (Text)
import qualified Data.Text                    as Text
import qualified Serv.Internal.Cors           as Cors
import qualified Serv.Internal.Server.Context as Ctx
import           Serv.Internal.Verb

swap (a, b) = (b, a)

newtype InContext m a
  = InContext { runInContext :: StateT Ctx.Context m a }
  deriving ( Functor, Applicative, Monad
           , MonadTrans
           , MonadState Ctx.Context
           , MonadIO
           )

instance Monad m => MonadReader Ctx.Context (InContext m) where
  ask = get
  local f m = do
    (ctx, a) <- fork (modify f >> m)
    return a

mapInContext :: (forall x . m x -> n x) -> InContext m a -> InContext n a
mapInContext phi (InContext r) = InContext (mapStateT phi r)

getVerb :: Monad m => InContext m (Maybe Verb)
getVerb = fmap parseVerb (asks Ctx.method)

pathIsEmpty :: Monad m => InContext m Bool
pathIsEmpty = asks Ctx.pathIsEmpty

fork :: Monad m => InContext m a -> InContext m (Ctx.Context, a)
fork (InContext m) = do
  ctx <- ask
  (a, newCtx) <- lift (runStateT m ctx)
  return (newCtx, a)

restore :: Monad m => (Ctx.Context, a) -> InContext m a
restore (ctx, a) = put ctx >> return a

takeSegment :: Monad m => InContext m (Maybe Text)
takeSegment = InContext (state $ swap . Ctx.takeSegment)

takeAllSegments :: Monad m => InContext m [Text]
takeAllSegments = InContext (state $ swap . Ctx.takeAllSegments)

addCorsPolicy :: Monad m => Cors.Policy -> InContext m ()
addCorsPolicy policy = modify $ \ctx ->
  ctx { Ctx.corsPolicies = policy : Ctx.corsPolicies ctx }
