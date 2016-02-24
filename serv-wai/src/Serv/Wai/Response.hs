{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs            #-}
{-# LANGUAGE KindSignatures   #-}
{-# LANGUAGE PolyKinds        #-}
{-# LANGUAGE TypeOperators    #-}

module Serv.Wai.Response where

import           Data.Singletons
import           Network.HTTP.Kinder.Header (HeaderEncode, headerEncodePair)
import           Network.HTTP.Kinder.Status (Status)
import qualified Network.HTTP.Types         as HTTP
import qualified Serv.Api                   as Api
import           Serv.Wai.Corec
import           Serv.Wai.Rec

-- | A value of type @'Response (status, 'Api.Respond' headers body)@
-- fully describes one response a Serv server might emit.
data Response (x :: (Status, Api.Output *)) where
  ContentResponse
    :: [HTTP.Header] -> FieldRec hs -> a
    -> Response '(s, Api.Respond hs (Api.HasBody ts a))
  EmptyResponse
    :: [HTTP.Header] -> FieldRec hs
    -> Response '(s, Api.Respond hs Api.Empty)

-- | A value of type @'SomeResponse rs'@ is a value of @'Response' (s, r)@
-- such that @(s, r)@ is an element of @rs@.
type SomeResponse rs = Corec Response rs

-- | Forget the details of a specific response making it an approprate
-- response at a given 'Api.Endpoint'
respond :: ElemOf rs '(s, r) => Response '(s, r) -> SomeResponse rs
respond = inject

-- | The empty response at a given status code: no headers, no body.
empty :: sing s -> Response '(s, Api.Respond '[] Api.Empty)
empty _ = EmptyResponse [] RNil

-- | Attach a body to an empty 'Response'.
addBody
  :: a -> Response '(s, Api.Respond hs Api.Empty)
  -> Response '(s, Api.Respond hs (Api.HasBody ts a))
addBody a (EmptyResponse secretHeaders headers) =
  ContentResponse secretHeaders headers a

-- | Eliminate a body in a 'Response', returning it to 'Api.Empty'.
removeBody
  :: Response '(s, Api.Respond hs (Api.HasBody ts a))
  -> Response '(s, Api.Respond hs Api.Empty)
removeBody (ContentResponse secretHeaders headers a) =
  EmptyResponse secretHeaders headers

-- | Adds a header to a 'Response'
addHeader
  :: Sing name -> value
  -> Response '(s, Api.Respond headers body)
  -> Response '(s, Api.Respond ( '(name, value) ': headers) body)
addHeader s val r = case r of
  ContentResponse secretHeaders headers body ->
    ContentResponse secretHeaders (s =: val <+> headers) body
  EmptyResponse secretHeaders headers ->
    EmptyResponse secretHeaders (s =: val <+> headers)

-- | Unlike 'addHeader', 'addHeaderQuiet' allows you to add headers not
-- explicitly specified in the api specification.
addHeaderQuiet
  :: HeaderEncode name value
  => Sing name -> value
  -> Response '(s, Api.Respond headers body)
  -> Response '(s, Api.Respond headers body)
addHeaderQuiet s value r =
  case headerEncodePair s value of
    Nothing -> r
    Just newHeader ->
      case r of
        ContentResponse secretHeaders headers body ->
          ContentResponse (newHeader : secretHeaders) headers body
        EmptyResponse secretHeaders headers ->
          EmptyResponse (newHeader : secretHeaders) headers