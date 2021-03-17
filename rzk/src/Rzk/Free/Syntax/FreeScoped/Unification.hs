{-# LANGUAGE DeriveFoldable             #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE RecordWildCards            #-}
module Rzk.Free.Syntax.FreeScoped.Unification where

import           Bound.Scope                (Scope, instantiate, toScope)
import           Bound.Term                 (substitute)
import           Bound.Var
import           Control.Applicative
import           Control.Monad.State
import           Data.Bifoldable
import           Data.Bifunctor
import           Data.Bitraversable
import qualified Data.Foldable              as F
import           Data.List                  (intersect, partition, union)
import           Data.String
import           Data.Text.Prettyprint.Doc  (Pretty (..))
import           Rzk.Free.Syntax.FreeScoped

import           Debug.Trace
import           Rzk.Free.Bound.Name
import           Rzk.Free.Parser
import           Rzk.Free.Pretty
import           Rzk.Free.Syntax.Term
import           Unsafe.Coerce

type UTerm b a v = UFreeScoped (Name b ()) (TermF b) a v

type UTerm' = UTerm Rzk.Free.Parser.Var Rzk.Free.Parser.Var Int

unsafeTraceUTerm' :: String -> a -> b -> b
unsafeTraceUTerm' tag x y = trace (tag <> " " <> show (unsafeCoerce x :: UTerm')) y

unsafeTraceConstraint' :: String -> a -> b -> b
unsafeTraceConstraint' tag x y = trace (tag <> " " <> show (unsafeCoerce x :: (UTerm', UTerm'))) y

unsafeTraceConstraints' :: String -> a -> b -> b
unsafeTraceConstraints' tag x y = trace (tag <> " " <> show (unsafeCoerce x :: [(UTerm', UTerm')])) y

data UVar b a v
  = UFreeVar a
  | UMetaVar v
  | UBoundVar v b
  deriving (Eq, Foldable)

instance IsString a => IsString (UVar b a v) where
  fromString = UFreeVar . fromString

instance (Pretty a, Pretty v) => Pretty (UVar b a v) where
  pretty (UFreeVar x)    = pretty x
  pretty (UMetaVar v)    = "?M" <> pretty v
  pretty (UBoundVar n b) = "[bound]" <> pretty n

type UFreeScoped b term a v = FreeScoped b term (UVar b a v)

class (Eq var, Monad m) => MonadBind term var m | m -> term var where
  lookupVar :: var -> m (Maybe term)
  freeVar :: m var
  newVar :: term -> m var
  bindVar :: var -> term -> m ()
  freshMeta :: m var

data BindState term var = BindState
  { bindings   :: [(var, term)]
  , freshVars  :: [var]
  , freshMetas :: var
  }

initBindState :: Enum var => BindState term var
initBindState = BindState
  { bindings = []
  , freshVars = []
  , freshMetas = toEnum 100
  }

newtype AssocBindT term var m a = AssocBindT
  { runAssocBindT :: StateT (BindState term var) m a
  } deriving (Functor, Applicative, Alternative, Monad, MonadPlus)

instance (Eq var, Enum var, Monad m) => MonadBind term var (AssocBindT term var m) where
  lookupVar x = AssocBindT (gets (lookup x . bindings))
  freeVar = AssocBindT $ do
    s@BindState{..} <- get
    let x:xs = freshVars
    put s {freshVars = xs}
    return x
  newVar t = AssocBindT $ do
    s@BindState{..} <- get
    let x:xs = freshVars
    put s
      { freshVars = xs
      , bindings = (x, t) : bindings
      }
    return x
  bindVar x t = AssocBindT $ do
    s@BindState{..} <- get
    put s { bindings = (x, t) : bindings }
  freshMeta = AssocBindT $ do
    s@BindState{..} <- get
    put s { freshMetas = succ freshMetas }
    return freshMetas

type Constraint b term a v = (UFreeScoped b term a v, UFreeScoped b term a v)

holesToMeta
  :: Bifunctor term
  => (a -> Bool) -> FreeScoped b term a -> UFreeScoped b term a a
holesToMeta isHole = fmap toMeta
  where
    toMeta x
      | isHole x  = UMetaVar x
      | otherwise = UFreeVar x

noHolesToMeta
  :: Bifunctor term
  => FreeScoped b term a -> UFreeScoped b term a v
noHolesToMeta = fmap UFreeVar

simplify
  :: ( MonadBind (UFreeScoped b term a v) v m
     , MonadPlus m
     , Bitraversable term
     , Eq a, Eq b, Eq v )
  => (UFreeScoped b term a v -> UFreeScoped b term a v)
  -> (forall s t. term s t
               -> term s t
               -> Maybe (term (Either s (s, s)) (Either t (t, t))))
  -> (UFreeScoped b term a v -> (UFreeScoped b term a v, [UFreeScoped b term a v]))
  -> Constraint b term a v
  -> m (Maybe [Constraint b term a v])
simplify reduce zipMatch peel (t1, t2)
  = unsafeTraceConstraint' "[simplify]" (t1, t2) $
  case (reduce t1, reduce t2) of
    (PureScoped b1@UBoundVar{}, PureScoped b2@UBoundVar{})
      | b1 == b2  -> return (Just [])
      | otherwise -> mzero
    (FreeScoped t1', FreeScoped t2')
      | Just t <- zipMatch t1' t2' -> do
          let go (Left _)           = return []
              go (Right (tt1, tt2)) = return [(tt1, tt2)]

              goScope (Left _) = return []
              goScope (Right (s1, s2)) = do
                i <- freshMeta
                let ss1 = instantiate (pure . UBoundVar i) s1
                    ss2 = instantiate (pure . UBoundVar i) s2
                return [(ss1, ss2)]
          Just . bifold <$> bitraverse goScope go t
    (t1', t2')
      | isStuck peel t1' || isStuck peel t2' -> return Nothing
    (t1', t2')
      | (PureScoped x1, args1) <- peel t1'
      , (PureScoped x2, args2) <- peel t2' -> do
          guard (x1 == x2)
          guard (length args1 == length args2)
          return (Just (zip args1 args2))
    _ -> return Nothing

repeatedlySimplify
  :: ( MonadBind (UFreeScoped b term a v) v m
     , MonadPlus m
     , Bitraversable term
     , Eq a, Eq b, Eq v )
  => (UFreeScoped b term a v -> UFreeScoped b term a v)
  -> (forall s t. term s t
               -> term s t
               -> Maybe (term (Either s (s, s)) (Either t (t, t))))
  -> (UFreeScoped b term a v -> (UFreeScoped b term a v, [UFreeScoped b term a v]))
  -> [Constraint b term a v]
  -> m [Constraint b term a v]
repeatedlySimplify reduce zipMatch peel = go
  where
    go [] = return []
    go (c:cs) = do
      simplify reduce zipMatch peel c >>= \case
        Nothing -> do
          cs' <- go cs
          return (c:cs')
        Just c' -> do
          go (c' <> cs)

type Subst b term a v = [(v, UFreeScoped b term a v)]

metavars :: Bifoldable term => UFreeScoped b term a v -> [v]
metavars = foldMap F.toList . F.toList

noUBoundVarsIn :: Bifoldable term => UFreeScoped b term a v -> Bool
noUBoundVarsIn = all notUBound . F.toList
  where
    notUBound UBoundVar{} = False
    notUBound _           = True

tryFlexRigid
  :: ( MonadBind (UFreeScoped b term a v) v m
     , MonadPlus m
     , Bitraversable term
     , Eq a, Eq b, Eq v )
  => (UFreeScoped b term a v -> (UFreeScoped b term a v, [UFreeScoped b term a v]))
  -> (forall x. FreeScoped b term x -> [FreeScoped b term x] -> FreeScoped b term x)
  -> (forall x. Int -> Scope Int (FreeScoped b term) (UVar b x v) -> UFreeScoped b term x v)
  -> Constraint b term a v -> [m [Subst b term a v]]
tryFlexRigid peel mkApps mkLams (t1, t2)
  | (PureScoped (UMetaVar i), cxt1) <- peel t1,
    (stuckTerm, cxt2) <- peel t2,
    not (i `elem` metavars t2) = proj (length cxt1) i stuckTerm 0
  | (PureScoped (UMetaVar i), cxt1) <- peel t2,
    (stuckTerm, cxt2) <- peel t1,
    not (i `elem` metavars t1) = proj (length cxt1) i stuckTerm 0
  | otherwise = []
  where proj bvars mv f nargs =
          generateSubst bvars mv f nargs : proj bvars mv f (nargs + 1)
        generateSubst bvars mv f nargs = do
          let saturateMV tm = mkApps tm (map (PureScoped . B) [0..bvars - 1])
          let mkSubst t = [(mv, t)]
          args <- map saturateMV . map (PureScoped . F . UMetaVar)
                    <$> replicateM nargs freshMeta
          return [mkSubst . mkLams bvars $ toScope $ mkApps t args
                 | t <- map (PureScoped . B) [0..bvars - 1] ++
                        if noUBoundVarsIn f then [fmap F f] else []]

substMV
  :: (Bifunctor term, Eq a, Eq v, Eq b)
  => UFreeScoped b term a v
  -> v
  -> UFreeScoped b term a v
  -> UFreeScoped b term a v
substMV new v t = substitute (UMetaVar v) new t

manySubst
  :: (Bifunctor term, Eq a, Eq v, Eq b)
  => Subst b term a v -> UFreeScoped b term a v -> UFreeScoped b term a v
manySubst s t = foldr (\(mv, t) sol -> substMV t mv sol) t s

(<+>)
  :: (Bifunctor term, Eq a, Eq v, Eq b)
  => Subst b term a v -> Subst b term a v -> Subst b term a v
-- s1 <+> s2 | not (null (intersect s1 s2)) = error "Impossible"
s1 <+> s2 = (fmap (manySubst s1) <$> s2) ++ s1

isStuck
  :: (UFreeScoped b term a v -> (UFreeScoped b term a v, [UFreeScoped b term a v]))
  -> UFreeScoped b term a v
  -> Bool
isStuck peel t =
  case peel t of
    (PureScoped UMetaVar{}, _) -> True
    _                          -> False

unify
  :: ( MonadBind (UFreeScoped b term a v) v m
     , MonadPlus m
     , Bitraversable term
     , Eq a, Eq b, Eq v )
  => (UFreeScoped b term a v -> UFreeScoped b term a v)
  -> (forall s t. term s t
               -> term s t
               -> Maybe (term (Either s (s, s)) (Either t (t, t))))
  -> (UFreeScoped b term a v -> (UFreeScoped b term a v, [UFreeScoped b term a v]))
  -> (forall x. FreeScoped b term x -> [FreeScoped b term x] -> FreeScoped b term x)
  -> (forall x. Int -> Scope Int (FreeScoped b term) (UVar b x v) -> UFreeScoped b term x v)
  -> Subst b term a v
  -> [Constraint b term a v]
  -> m (Subst b term a v, [Constraint b term a v])
unify reduce zipMatch peel mkApps mkLams s cs = do
  unsafeTraceConstraints' "[unify]" cs $ do
    let cs' = applySubst s cs
    unsafeTraceConstraints' "[unify2]" cs' $ do
      cs'' <- repeatedlySimplify reduce zipMatch peel cs'
      let (flexflexes, flexrigids) = partition flexflex cs''
      traceShow (length flexflexes, length flexrigids) $
        case flexrigids of
          [] -> return (s, flexflexes)
          fr:_ -> do
            let psubsts = tryFlexRigid peel mkApps mkLams fr
            trySubsts psubsts (flexrigids <> flexflexes)
  where
    applySubst s = map (\(t1, t2) -> (manySubst s t1, manySubst s t2))
    flexflex (t1, t2) = isStuck peel t1 && isStuck peel t2
    trySubsts [] cs = mzero
    trySubsts (mss : psubsts) cs = do
      ss <- mss
      let these = foldr mplus mzero [unify reduce zipMatch peel mkApps mkLams (newS <+> s) cs | newS <- ss]
      let those = trySubsts psubsts cs
      these `mplus` those

driver
  :: (MonadPlus m, Enum v, Bitraversable term, Eq v, Eq a, Eq b)
  => (UFreeScoped b term a v -> UFreeScoped b term a v)
  -> (forall s t. term s t
               -> term s t
               -> Maybe (term (Either s (s, s)) (Either t (t, t))))
  -> (UFreeScoped b term a v -> (UFreeScoped b term a v, [UFreeScoped b term a v]))
  -> (forall x. FreeScoped b term x -> [FreeScoped b term x] -> FreeScoped b term x)
  -> (forall x. Int -> Scope Int (FreeScoped b term) (UVar b x v) -> UFreeScoped b term x v)
  -> Constraint b term a v
  -> m (Subst b term a v, [Constraint b term a v])
driver reduce zipMatch peel mkApps mkLams
  = flip evalStateT initBindState
  . runAssocBindT
  . unify reduce zipMatch peel mkApps mkLams []
  . (\x -> [x])
