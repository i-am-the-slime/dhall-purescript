module Dhall.Test.Standard where

import Prelude

import Control.Comonad (extract)
import Control.Monad.Writer (WriterT(..))
import Data.Array (foldMap)
import Data.Array as Array
import Data.Foldable (traverse_)
import Data.Maybe (Maybe(..), fromMaybe, isJust)
import Data.Newtype (unwrap)
import Data.String (Pattern(..), stripSuffix)
import Data.Tuple (Tuple(..), fst)
import Data.Variant (Variant)
import Dhall.Core (alphaNormalize)
import Dhall.Core as AST
import Dhall.Core.CBOR (decode)
import Dhall.Core.Imports.Resolve as Resolve
import Dhall.Core.Imports.Retrieve (nodeReadBinary, nodeRetrieveFile)
import Dhall.Lib.CBOR as CBOR
import Dhall.Map (InsOrdStrMap)
import Dhall.Test as Test
import Dhall.Test.Util (eqArrayBuffer)
import Dhall.Test.Util as Util
import Dhall.TypeCheck as TC
import Effect (Effect)
import Effect.Aff (Aff, catchError, error, launchAff_, message, throwError)
import Effect.Class (liftEffect)
import Effect.Class.Console (log)
import Effect.Ref as Ref
import Node.Path (FilePath)
import Validation.These as V

root = "./dhall-lang/tests/" :: String

note :: String -> Maybe ~> Aff
note msg Nothing = throwError (error (msg))
note _ (Just a) = pure a

noteFb :: forall w e a. Show (Variant e) =>
  String -> TC.Feedback w e InsOrdStrMap a ~> Aff
noteFb msg (WriterT (V.Error es _)) =
  throwError (error (msg <> foldMap (\(TC.TypeCheckError { tag }) -> "\n    " <> show tag) es))
noteFb _ (WriterT (V.Success (Tuple a _))) = pure a

etonFb :: forall w e a b.
  String -> TC.Feedback w e InsOrdStrMap a b -> Aff Unit
etonFb _ (WriterT (V.Error es _)) = pure unit
etonFb msg (WriterT (V.Success (Tuple a _))) = throwError (error msg)

logErrorWith :: Aff Unit -> Aff Unit -> Aff Unit
logErrorWith desc = catchError <@> \err ->
  desc *> log ("  " <> message err)

testType :: String -> (FilePath -> Aff Unit) -> (FilePath -> Aff Unit) -> Aff Unit
testType ty = testType' ty ".dhall"

testType' :: String -> String -> (FilePath -> Aff Unit) -> (FilePath -> Aff Unit) -> Aff Unit
testType' ty suff success failure = do
  successes <- Util.discover2 ("A" <> suff) $ root <> ty <> "/success"
  count0 <- liftEffect $ Ref.new 0
  let incr0 f a = f a <* do liftEffect $ Ref.modify_ (_ + 1) count0
  traverse_ (logErrorWith <$> log <*> incr0 success) successes
  count1 <- liftEffect $ Ref.new 0
  let incr1 f a = f a <* do liftEffect $ Ref.modify_ (_ + 1) count1
  failures <- Util.discover2 suff $ root <> ty <> "/failure"
  traverse_ (logErrorWith <$> log <*> incr1 failure) failures
  counted0 <- liftEffect $ Ref.read count0
  counted1 <- liftEffect $ Ref.read count1
  log $ ty <> " score: (" <> show counted0 <> " + " <> show counted1 <> ") / (" <>
    (show $ Array.length successes) <> " + " <> (show $ Array.length failures) <> ") = " <> (show $ (100 * (counted0 + counted1)) / (Array.length successes + Array.length failures)) <> "%"

test :: Aff Unit
test = do
  testType "parser"
    do \success -> do
        textA <- nodeRetrieveFile (success <> "A.dhall")
        let actA = Test.mkActions textA
        parsedA <- actA.parse # unwrap # extract #
          note "Failed to parse A"
        binB <- nodeReadBinary (success <> "B.dhallb")
        when ((extract parsedA.encoded).cbor `not eqArrayBuffer` binB) do
          throwError (error "Binary did not match")
    do \failure -> do
        text <- nodeRetrieveFile (failure <> ".dhall")
        let act = Test.mkActions text
        let parsed = act.parse # unwrap # extract
        when (isJust parsed) do
          throwError (error "Was not supposed to parse")
  testType "normalization"
    do \success -> do
        textA <- nodeRetrieveFile (success <> "A.dhall")
        let actA = Test.mkActions textA
        parsedA <- actA.parse # unwrap # extract #
          note "Failed to parse A"
        textB <- nodeRetrieveFile (success <> "B.dhall")
        let actB = Test.mkActions textB
        parsedB <- actB.parse # unwrap # extract #
          note "Failed to parse B"
        when (extract parsedA.unsafeNormalized /= parsedB.parsed) do
          throwError (error "Normalization did not match")
    do \failure ->
        throwError (error "Why is there a normalization failure?")
  testType "alpha-normalization"
    do \success -> do
        textA <- nodeRetrieveFile (success <> "A.dhall")
        let actA = Test.mkActions textA
        parsedA <- actA.parse # unwrap # extract #
          note "Failed to parse A"
        textB <- nodeRetrieveFile (success <> "B.dhall")
        let actB = Test.mkActions textB
        parsedB <- actB.parse # unwrap # extract #
          note "Failed to parse B"
        when (alphaNormalize parsedA.parsed /= parsedB.parsed) do
          throwError (error "Alpha-normalization did not match")
    do \failure ->
        throwError (error "Why is there an alpha-normalization failure?")
  testType "semantic-hash"
    do \success -> do
        textA <- nodeRetrieveFile (success <> "A.dhall")
        let actA = Test.mkActions textA
        parsedA <- actA.parse # unwrap # extract #
          note "Failed to parse"
        importedA <- parsedA.imports # unwrap # extract # unwrap >>=
          noteFb "Failed to resolve A"
        typecheckedA <- importedA.typechecked # unwrap # extract #
          noteFb "Failed to typecheck A"
        hashB <- (fromMaybe <*> stripSuffix (Pattern "\n")) <$> nodeRetrieveFile (success <> "B.hash")
        let hashA = "sha256:" <> (extract typecheckedA.encoded).hash
        when (hashA /= hashB) do
          throwError $ error $ "Binary did not match"
            <> "\n    Got: " <> hashA
            <> "\n    Exp: " <> hashB
    do \failure ->
        throwError (error "Why is there a semantic hash failure?")
  testType "typecheck"
    do \success -> do
        textA <- nodeRetrieveFile (success <> "A.dhall")
        let actA = Test.mkActions textA
        parsedA <- actA.parse # unwrap # extract #
          note "Failed to parse A"
        importedA <- parsedA.imports # unwrap # extract # unwrap >>=
          noteFb "Failed to resolve A"
        textB <- nodeRetrieveFile (success <> "B.dhall")
        let actB = Test.mkActions textB
        parsedB <- actB.parse # unwrap # extract #
          note "Failed to parse B"
        importedB <- parsedB.imports # unwrap # fst # unwrap # extract #
          note "Failed to resolve B"
        void $ Test.tc' (AST.mkAnnot importedA.resolved importedB.resolved) #
          noteFb "Typechecking failed"
    do \failure -> do
        text <- nodeRetrieveFile (failure <> ".dhall")
        let act = Test.mkActions text
        parsed <- act.parse # unwrap # extract #
          note "Failed to parse"
        imported <- parsed.imports # unwrap # extract # unwrap >>=
          noteFb "Failed to resolve"
        imported.typechecked # unwrap # extract #
          etonFb "Was not supposed to typecheck"
  testType "type-inference"
    do \success -> do
        textA <- nodeRetrieveFile (success <> "A.dhall")
        let actA = Test.mkActions textA
        parsedA <- actA.parse # unwrap # extract #
          note "Failed to parse A"
        importedA <- parsedA.imports # unwrap # extract # unwrap >>=
          noteFb "Failed to resolve A"
        typecheckedA <- importedA.typechecked # unwrap # extract #
          noteFb "Failed to typecheck A"
        textB <- nodeRetrieveFile (success <> "B.dhall")
        let actB = Test.mkActions textB
        parsedB <- actB.parse # unwrap # extract #
          note "Failed to parse B"
        importedB <- parsedB.imports # unwrap # fst # unwrap # extract #
          note "Failed to resolve B"
        when (extract typecheckedA.normalizedType /= importedB.resolved) do
          throwError (error "Type inference did not match")
    do \failure ->
        throwError (error "Why is there a type-inference failure?")
  testType' "binary-decode" ".dhallb"
    do \success -> do
        binA <- nodeReadBinary (success <> "A.dhallb")
        decodedA <- binA # CBOR.decode # decode #
          note "Failed to decode A"
        textB <- nodeRetrieveFile (success <> "B.dhall")
        let actB = Test.mkActions textB
        parsedB <- actB.parse # unwrap # extract #
          note "Failed to parse B"
        when (decodedA /= parsedB.parsed) do
          throwError (error "Binary did not match")
    do \failure -> do
        bin <- nodeReadBinary (failure <> ".dhallb")
        let decoded = (bin # CBOR.decode # decode) :: Maybe Resolve.ImportExpr
        when (isJust decoded) do
          throwError (error "Was not supposed to decode")

main :: Effect Unit
main = launchAff_ test
