module Dhall.Core.AST.Operations where

import Prelude

import Data.Functor.Variant (VariantF)
import Data.Functor.Variant as VariantF
import Dhall.Core.AST.Types (Expr, ExprLayerRow, embedW, projectW)
import Prim.Row as Row

-- Some general operations for the Expr AST

-- | Just a helper to handle recursive rewrites: top-down, requires explicit
-- | recursion for the cases that are handled by the rewrite.
rewriteTopDown :: forall r r' m a b.
  Row.Union r r' (ExprLayerRow m b) =>
  (
    (VariantF r (Expr m a) -> Expr m b) ->
    VariantF (ExprLayerRow m a) (Expr m a) ->
    Expr m b
  ) ->
  Expr m a -> Expr m b
rewriteTopDown rw1 = go where
  go expr = rw1 (map go >>> VariantF.expand >>> embedW) $ projectW expr

-- | Another recursion helper: bottom-up, recursion already happens before
-- | the rewrite gets ahold of it. Just follow the types.
rewriteBottomUp :: forall r r' m a b.
  Row.Union r r' (ExprLayerRow m b) =>
  (
    (VariantF r (Expr m b) -> Expr m b) ->
    VariantF (ExprLayerRow m a) (Expr m b) ->
    Expr m b
  ) ->
  Expr m a -> Expr m b
rewriteBottomUp rw1 = go where
  go expr = rw1 (VariantF.expand >>> embedW) $ go <$> projectW expr
