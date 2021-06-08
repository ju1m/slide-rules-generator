{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleContexts #-}
module SlideRules.Generator where

-- base
import qualified Data.Sequence as S

-- containers
import qualified Data.Map.Strict as M

-- default
import Data.Default

-- lens
import Control.Lens.Combinators hiding (each)
import Control.Lens.Operators
import Control.Lens.TH (makeLenses)

-- mtl
import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.List

-- local (sliderules)
import SlideRules.Tick
import SlideRules.Transformations
import SlideRules.Types
import SlideRules.Utils

type Generator = ListT (ReaderT Settings (State GenState))

type TickCreator = InternalFloat -> TickInfo

data Settings = Settings
    { tolerance :: InternalFloat
    }

data GenState = GenState
    { _preTransformations      :: [Transformation]
    , _postTransformations     :: [Transformation]
    , _postPostTransformations :: [Transformation]
    , _tickCreator             :: TickCreator
    , _scaleSelector           :: TickF () -> ScaleID
    , _out                     :: M.Map ScaleID (S.Seq Tick)
    , _logging                 :: S.Seq String
    }
    -- deriving (Show)

instance Default GenState where
    def = GenState
        { _preTransformations = []
        , _postTransformations = []
        , _postPostTransformations = []
        , _tickCreator = const def
        , _scaleSelector = const ""
        , _out = M.empty
        , _logging = S.fromList []
        }

makeLenses ''GenState

generate :: Settings -> Generator a -> GenState
generate settings act = generateWith settings act def

generateWith :: Settings -> Generator a -> GenState -> GenState
generateWith settings act = execState $ runReaderT (runListT act) settings

summarize :: Settings -> Generator a -> [(String, InternalFloat, InternalFloat)]
summarize settings = (foldMap . foldMap) summarize1 . _out . generate settings
    where
        summarize1 tick =
            case tick ^. info . mlabel of
                Nothing -> []
                Just label -> [(label ^. text, tick ^. prePos, tick ^. postPos)]

calculate :: InternalFloat -> GenState -> Maybe (TickF ())
calculate x s = do
    _prePos <- runTransformations (_preTransformations s) x
    _postPos <- runTransformations (_postTransformations s) _prePos
    let _postPostPos = runTransformations (_postPostTransformations s) _postPos
    pure $ Tick { _prePos, _postPos, _postPostPos, _info = () }

genTick :: InternalFloat -> GenState -> Maybe Tick
genTick x s = do
    Tick { _prePos, _postPos, _postPostPos } <- calculate x s
    let _info = _tickCreator s _prePos
    pure $ Tick { _info, _prePos, _postPos, _postPostPos }

list :: [a] -> Generator a
list xs = ListT $ pure xs

together :: [Generator a] -> Generator a
together = join . list

withPrevious :: Lens' GenState a -> (a -> a) -> Generator b -> Generator b
withPrevious lens f action = do
    previous <- use lens
    Right res <- together
        [ fmap Left $ lens %= f
        , fmap Right action
        , fmap Left $ lens .= previous
        ]
    return res

preTransform :: Transformation -> Generator a -> Generator a
preTransform transformation = withPrevious preTransformations (transformation :)

postTransform :: Transformation -> Generator a -> Generator a
postTransform transformation = withPrevious postTransformations (transformation :)

postPostTransform :: Transformation -> Generator a -> Generator a
postPostTransform transformation = withPrevious postPostTransformations (transformation :)

translate :: InternalFloat -> InternalFloat -> Generator a -> Generator a
translate offset scale = preTransform (Offset offset) . preTransform (Scale scale)

scaleSelect :: (TickF () -> ScaleID) -> Generator a -> Generator a
scaleSelect selector = withPrevious scaleSelector (const selector)

withTickCreator :: ((InternalFloat -> TickInfo) -> InternalFloat -> TickInfo) -> Generator a -> Generator a
withTickCreator handlerF = withPrevious tickCreator handlerF

fromInfoX :: (TickInfo -> InternalFloat -> TickInfo) -> ((InternalFloat -> TickInfo) -> InternalFloat -> TickInfo)
fromInfoX handlerF = \f x -> handlerF (f x) x

withInfoX :: (TickInfo -> InternalFloat -> TickInfo) -> Generator a -> Generator a
withInfoX handlerF = withTickCreator (fromInfoX handlerF)

fromXInfo :: (InternalFloat -> TickInfo -> TickInfo) -> ((InternalFloat -> TickInfo) -> InternalFloat -> TickInfo)
fromXInfo handlerF = fromInfoX (flip handlerF)

withXInfo :: (InternalFloat -> TickInfo -> TickInfo) -> Generator a -> Generator a
withXInfo handlerF = withTickCreator (fromXInfo handlerF)

fromInfo :: (TickInfo -> TickInfo) -> ((InternalFloat -> TickInfo) -> InternalFloat -> TickInfo)
fromInfo handlerF = fromXInfo (const handlerF)

withInfo :: (TickInfo -> TickInfo) -> Generator a -> Generator a
withInfo handlerF = withTickCreator (fromInfo handlerF)

output :: InternalFloat -> Generator ()
output x = do
    Just tick <- gets $ genTick x
    scaleID <- use scaleSelector <*> pure (deinfo tick)
    out %= M.insertWith (<>) scaleID (S.singleton tick)

saveToLog :: String -> Generator ()
saveToLog s = logging <>= S.fromList [s]

withs :: [Generator a -> Generator a] -> Generator a -> Generator a
withs = foldr (.) id

-- Do not show postPostPos here - it should not be visible
measure :: InternalFloat -> InternalFloat -> Generator (InternalFloat, InternalFloat)
measure a b = do
    Just (Tick { _prePos = preA, _postPos = postA }) <- gets (calculate a)
    Just (Tick { _prePos = preB, _postPos = postB }) <- gets (calculate b)
    return (preB - preA, postB - postA)
