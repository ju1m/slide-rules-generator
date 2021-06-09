{-# LANGUAGE TupleSections #-}
module SlideRules.Scales where

-- base
import Data.Foldable (fold)

-- containers
import qualified Data.Map.Strict as M
import qualified Data.Sequence as S

-- diagrams-*
import qualified Diagrams.Backend.SVG         as D
import qualified Diagrams.Backend.SVG.CmdLine as D
import qualified Diagrams.Prelude             as D
import qualified Diagrams.TwoD.Text           as D
import qualified Diagrams.TwoD.Vector         as D

-- local (sliderules)
import SlideRules.Generator
import SlideRules.Partitions
import SlideRules.Tick
import SlideRules.Transformations
import SlideRules.Types
import SlideRules.Utils

data ScaleID = IID Integer | SID String
    deriving (Eq, Ord)

generateScales :: (InternalFloat -> [(InternalFloat, ScaleID)]) -> Settings -> Generator a -> M.Map ScaleID (S.Seq Tick)
generateScales tickIdentifiers settings generator =
    let ticks = generateTicksOnly settings generator
        tickIdentifiersFromPostPost = maybe [] tickIdentifiers . _postPostPos
        insertTick tick map =
            foldr
                (\(x', id) -> M.insertWith (<>) id (S.singleton $ tick { _postPostPos = Just x' }))
                map
                (tickIdentifiersFromPostPost tick)
        identifiedTicks = foldr insertTick M.empty ticks
    in
    identifiedTicks

generateTicksOnly :: Settings -> Generator a -> S.Seq Tick
generateTicksOnly settings = _out . generate settings

renderScaleTicks :: Foldable f => f Tick -> D.Diagram D.B
renderScaleTicks ticks =
    let tickDias = foldMap renderTick ticks
        underlineDia = D.lc D.blue (laserline [D.r2 (0, 0), D.r2 (1, 0)])
        anchorDia = D.lc D.green (laserline [D.r2 (0, 0), D.r2 (-0.01, 0), D.r2 (0, 0.01)])
    in
    tickDias <> underlineDia <> anchorDia

genAndRender :: (InternalFloat -> [(InternalFloat, ScaleID)]) -> Settings -> Generator a -> [D.Diagram D.B]
genAndRender tickIdentifiers settings =
    fmap renderScaleTicks . M.elems . generateScales tickIdentifiers settings

genAndRenderSingle :: Settings -> Generator a -> [D.Diagram D.B]
genAndRenderSingle = genAndRender (\x -> [(x, SID "default")])

genAndRenderFloor :: (Integer, Integer) -> Settings -> Generator a -> [D.Diagram D.B]
genAndRenderFloor (lower, upper) = genAndRender tickIdentifiers
    where
        tickIdentifiers :: InternalFloat -> [(InternalFloat, ScaleID)]
        tickIdentifiers x =
            let handleI i =
                    [ (1, IID $ i - 1)
                    | i - 1 >= lower
                    ] ++
                    [ (0, IID i)
                    | i <= upper
                    ]
                handleF f =
                    [ (f - fromIntegral (floor f), IID $ floor f)
                    | f > fromIntegral lower
                    ]
            in
            showIOrF
                handleI
                handleF
                x
