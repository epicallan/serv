{-# LANGUAGE DataKinds      #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE GADTs          #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TypeOperators  #-}

module Serv.Internal.Server.Response where

import           Data.Function                      ((&))
import           Data.Singletons
import           GHC.TypeLits
import qualified Network.HTTP.Types                 as HTTP
import           Serv.Internal.Api
import           Serv.Internal.Header
import           Serv.Internal.Header.Serialization
import           Serv.Internal.Pair
import           Serv.Internal.Rec

-- | Responses generated in 'Server' implementations.
data Response (headers :: [ (HeaderType Symbol, *) ]) body where
  Response
    :: HTTP.Status
    -> [HTTP.Header]
    -> Rec headers
    -> a
    -> Response headers ('HasBody ctypes a)
  EmptyResponse
    :: HTTP.Status
    -> [HTTP.Header]
    -> Rec headers
    -> Response headers 'Empty

-- An 'emptyResponse' returns the provided status message with no body or headers
emptyResponse :: HTTP.Status -> Response '[] 'Empty
emptyResponse status = EmptyResponse status [] Nil

-- | Adds a body to a response
withBody
  :: a -> Response headers 'Empty -> Response headers ('HasBody ctypes a)
withBody a (EmptyResponse status secretHeaders headers) =
  Response status secretHeaders headers a

-- | Adds a header to a response
withHeader
  :: Sing name -> value
  -> Response headers body -> Response (name ::: value ': headers) body
withHeader s val r = case r of
  Response status secretHeaders headers body ->
    Response status secretHeaders (headers & s -: val) body
  EmptyResponse status secretHeaders headers ->
    EmptyResponse status secretHeaders (headers & s -: val)

-- | Unlike 'withHeader', 'withQuietHeader' allows you to add headers
-- not explicitly specified in the api specification.
withQuietHeader
  :: HeaderEncode name value
     => Sing name -> value
     -> Response headers body -> Response headers body
withQuietHeader s value r =
  case headerPair s value of
    Nothing -> r
    Just newHeader ->
      case r of
        Response status secretHeaders headers body ->
          Response status (newHeader : secretHeaders) headers body
        EmptyResponse status secretHeaders headers ->
          EmptyResponse status (newHeader : secretHeaders) headers

-- | If a response type is complete defined by its implementation then
-- applying 'resorted' to it will future proof it against reorderings
-- of headers. If the response type is not completely inferrable, however,
-- then this will require manual annotations of the "pre-sorted" response.
resortHeaders :: RecordIso headers headers' => Response headers body -> Response headers' body
resortHeaders r =
  case r of
    Response status secretHeaders headers body ->
      Response status secretHeaders (reorder headers) body
    EmptyResponse status secretHeaders headers ->
      EmptyResponse status secretHeaders (reorder headers)

-- | Used primarily for implementing @HEAD@ request automatically.
deleteBody :: Response headers body -> Response headers 'Empty
deleteBody r =
  case r of
    Response status secretHeaders headers _ ->
      EmptyResponse status secretHeaders headers
    EmptyResponse{} -> r
