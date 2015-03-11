require 'torch'
require 'nn'
require 'optim'
require 'xlua'  
dofile 'helpers.lua'
--These functions assume:
--all models use the same optimState 
--all models are of the same type, and differ by the parameters, or transformations to the data
  
function CreateModels(opt, parameters, modelGen, model_optim_critList)
  --Setup
    parameterList = {}
    if #parameters == 0 then
      for i =1,opt.models do
        table.insert(parameterList, parameters)
      end    
    elseif opt.models ~= #parameters then
      print '#models ~= #parameter sets'
      return
    else
      parameterList = parameters
    end
    --Creating models
    if model_optim_critList == nil then
      model_optim_critList = {}
      for i = 1,#parameters do
        table.insert(model_optim_critList, modelGen(parameterList[i]))
      end
    else--If not empty, modelGen is of form modelGen(parameters, modelToAugment)
      for i = 1,#parameters do
        table.insert(model_optim_critList, modelGen(parameterList[i], model_optim_critList[i]))
      end
    end
    return model_optim_critList
end
--Minor note: The absolute minimum number of epochs is opt.maxEpoch+1
function TrainModels(model_optim_critList, opt, trainData, trainFun, folds, logpackages)
  --Setup and invalid data checking
  if opt.models ~= #model_optim_critList then
    print 'Model sizes to not match up.'
    return
  end
  local Train = trainFun
  --Create folds as needed
  if type(folds) == 'table' then
    if #folds ~= #model_optim_critList then
      print '#folds ~= #models'
      return
    end
  elseif type(folds) == 'number' then
    if folds > 1 and folds ~= #model_optim_critList then
      print 'Fold is a number; mismatch with models'
      return
    end
    if folds <= 1 and #model_optim_critList ~= 1 then
      folds = CreateFolds(folds, trainData.size)
      local temp = folds
      folds = {}
      for i = 1,#model_optim_critList do
        table.insert(folds, temp[1])
      end
    else
      folds = CreateFolds(folds, trainData.size)
    end
  else
    print 'INVALID FOLD DATA TYPE'
    return
  end
  --Setup internals
  local modelResults = {}
  for i=1,#model_optim_critList do 
    table.insert(modelResults, {bestPercentError=1.1, epochsLeft=opt.maxEpoch, finished= false, model=nil}) 
  end
  local trainLoop = 
    function(foldIndex)         
      if logpackages ~= nil then 
        logpackage = logpackages[foldIndex] 
      else
        print 'NEED LOGPACKAGE. NO LOGGING NOT SUPPORTED'
        return
      end
      --Get inidices
      --Train logic
      if not modelResults[foldIndex].finished then 
        print('===>Training')
        --Train model
        logpackage.trainConfusion:zero()
        opt.noutputs = parameters.noutputs
        local trainingResult = Train(model_optim_critList[foldIndex], trainData, opt, logpackage.trainConfusion, folds[foldIndex].training)
        print ('===>Training error percentage: ' .. trainingResult.err)
        --Test on validation
        if folds[foldIndex].validation ~= nil then 
          logpackage.testConfusion:zero()
          print '===>Testing'
          validationResult = Test(model_optim_critList[foldIndex].model, trainData, opt, logpackage.testConfusion, folds[foldIndex].validation)
          print ('===>Validation error percentage: ' .. validationResult.err)
          percentError = validationResult.err 
        else 
          --If we don't have a validation set
          print '===>No Test Data'
          percentError = trainingResult.err
        end
        --Update
        if modelResults[foldIndex].bestPercentError > percentError then--If percent error goes down, update
          print('===>Updating best model')
          modelResults[foldIndex].bestPercentError = percentError
          modelResults[foldIndex].epochsLeft = opt.maxEpoch + 1
          modelResults[foldIndex].model = model_optim_critList[foldIndex].model:clone()
        end      
        modelResults[foldIndex].epochsLeft = modelResults[foldIndex].epochsLeft -1
        logpackage:log()--Log iteration
        
        --Convergence conditions
        if modelResults[foldIndex].epochsLeft == 0 or modelResults[foldIndex].bestPercentError < 1e-2 then
          modelResults[foldIndex].finished = true
          return 1 --Return 1 when the model finishes
        end
      else
        print('===>Finished training. Skipping.')
      end  
      return 0
    end
  --Setup more variables
  local epoch = 1
  local foldIndex = 0
  local numberConverged = 0
  local conc
  --Loop until all models converge
  print('===>Training ' .. #model_optim_critList .. ' models.')
  local time = os.time()
  while numberConverged ~= #model_optim_critList and os.difftime(os.time(), time) < opt.maxtime * 60  do
    foldIndex = (foldIndex % #model_optim_critList) + 1
    print('\n===>Training model ' .. foldIndex .. ' epoch: ' .. math.ceil(epoch/opt.models).. '\n')
    numberConverged = numberConverged + trainLoop(foldIndex)
    --Save a combined model every epoch
    if foldIndex == #model_optim_critList then 
      if opt.models ~= 1 then 
        conc = nn.Concat(1)
        for i = 1,opt.models do
          conc:add(modelResults[i].model:clone())
        end
        AddLSMtoConcatChildren(conc)
      else
        conc = modelResults[1].model
      end
      LogModel(opt.modelName, conc)
    end
    epoch = epoch + 1
  end
  print ('\n===>Completed training, took ' .. math.ceil((epoch-1)/opt.models) .. ' epochs.')
  return conc
end