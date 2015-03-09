require 'nn'
require 'torch'
require 'cunn'
require 'math'
require 'image'
require 'optim'
require 'xlua'





function create_network( classes_count, input_size )
 	
	-- this function creates a network for the surrogate task
	-- the network generated when cuda is available is a much more complicated architecture

	input_size = input_size or 36
 	noutputs = classes_count
	nfeats = 3
	width = input_size
	height = input_size
	ninputs = nfeats * width * height
	
	filtsize = 5
	poolsize = 2

	if opt.type == 'cuda' then

		nstates = {64,128,256,512}

		model = nn.Sequential()
		-- stage 1 : filter bank -> squashing -> L2 pooling -> normalization
	  	--model:add(nn.SpatialConvolutionMM(nfeats, nstates[1], filtsize, filtsize))
	  	--model:add(nn.ReLU())
	  	--model:add(nn.SpatialMaxPooling(poolsize,poolsize,poolsize,poolsize))

	  	-- stage 2 : filter bank -> squashing -> L2 pooling -> normalization
		model:add(nn.SpatialConvolutionMM(nfeats, nstates[2], filtsize, filtsize))
	  	model:add(nn.ReLU())
	  	model:add(nn.SpatialMaxPooling(poolsize,poolsize,poolsize,poolsize))

	  	-- stage 3 : filter bank -> squashing -> L2 pooling -> normalization
	  	model:add(nn.SpatialConvolutionMM(nstates[2], nstates[3], filtsize, filtsize))
	  	model:add(nn.ReLU())
	  	model:add(nn.SpatialMaxPooling(poolsize,poolsize,poolsize,poolsize))

	  	-- stage 4 : standard 2-layer neural network
	  	model:add(nn.View(nstates[3]*(filtsize+1)*(filtsize+1)))
	  	model:add(nn.Dropout(0.5))
	  	model:add(nn.Linear(nstates[3]*(filtsize+1)*(filtsize+1), nstates[4]))
	  	model:add(nn.ReLU())
	  	model:add(nn.Linear(nstates[4], noutputs))
		model:add(nn.LogSoftMax())
		criterion = nn.ClassNLLCriterion()
	else
	  n_states = {64,64,128}
      -- a typical convolutional network, with locally-normalized hidden
      -- units, and L2-pooling

      -- Note: the architecture of this convnet is loosely based on Pierre Sermanet's
      -- work on this dataset (http://arxiv.org/abs/1204.3968). In particular
      -- the use of LP-pooling (with P=2) has a very positive impact on
      -- generalization. Normalization is not done exactly as proposed in
      -- the paper, and low-level (first layer) features are not fed to
      -- the classifier.

      model = nn.Sequential()

      -- stage 1 : filter bank -> squashing -> L2 pooling -> normalization
      model:add(nn.SpatialConvolutionMM(nfeats, nstates[1], filtsize, filtsize))
      model:add(nn.Tanh())
      model:add(nn.SpatialLPPooling(nstates[1],2,poolsize,poolsize,poolsize,poolsize))
      model:add(nn.SpatialSubtractiveNormalization(nstates[1], normkernel))

      -- stage 2 : filter bank -> squashing -> L2 pooling -> normalization
      model:add(nn.SpatialConvolutionMM(nstates[1], nstates[2], filtsize, filtsize))
      model:add(nn.Tanh())
      model:add(nn.SpatialLPPooling(nstates[2],2,poolsize,poolsize,poolsize,poolsize))
      model:add(nn.SpatialSubtractiveNormalization(nstates[2], normkernel))

      -- stage 3 : standard 2-layer neural network
      dim = ((width - filtsize + 1)/poolsize - filtsize + 1)/poolsize
      model:add(nn.Reshape(nstates[2]*dim*dim))
      model:add(nn.Linear(nstates[2]*dim*dim, nstates[3]))
      model:add(nn.Tanh())
      model:add(nn.Linear(nstates[3], noutputs))
   end
 	print '==> here is the model:'
	print(model)
	return model,criterion
 end 

function train_model(model, criterion, trainData)
   if opt.type == 'cuda' then
	model:cuda()
	criterion:cuda()
   end
   print '==> configuring optimizer'

   optimState = {
      learningRate = opt.learningRate,
      weightDecay = opt.weightDecay,
      momentum = opt.momentum,
      learningRateDecay = 1e-7
   }

   optimMethod = optim.sgd

----------------------------------------------------------------------
print '==> defining training procedure'


--trainLogger = optim.Logger(paths.concat(opt.save, 'train.log'))
--testLogger = optim.Logger(paths.concat(opt.save, 'test.log'))
--paramLogger = optim.Logger(paths.concat(opt.save, 'params.log'))


--paramLogger:add{['maxIter'] = opt.maxIter, ['momentum'] = opt.momentum,
 --['weightDecay'] = opt.weightDecay, ['model'] = opt.model, ['optimization'] = opt.optimization, ['learningRate'] = opt.learningRate, ['loss'] = opt.loss, ['batchSize'] = opt.batchSize}

if model then
   parameters,gradParameters = model:getParameters()
end


   -- epoch tracker
   epoch = epoch or 1

   -- local vars
   local time = sys.clock()

   -- set model to training mode (for modules that differ in training and testing, like Dropout)
   model:training()

   -- shuffle at each epoch
   shuffle = torch.randperm(trainData:size()[1])

   -- do one epoch
   print('==> doing epoch on training data:')
   print("==> online epoch # " .. epoch .. ' [batchSize = ' .. opt.batchSize .. ']')
   for t = 1,trainData:size()[1],opt.batchSize do
      -- disp progress
      xlua.progress(t, trainData:size()[1])

      -- create mini batch
      local inputs = {}
      local targets = {}
      for i = t,math.min(t+opt.batchSize-1,trainData:size()[1]) do
         -- load new sample
         local input = trainData.data[shuffle[i]]
         
         local target = trainData.labels[shuffle[i]]
         if opt.type == 'double' then input = input:double()
         elseif opt.type == 'cuda' then input = input:cuda() end
         table.insert(inputs, input)
         table.insert(targets, target)
      end

      -- create closure to evaluate f(X) and df/dX
      local feval = function(x)
                       -- get new parameters
                       if x ~= parameters then
                          parameters:copy(x)
                       end

                       -- reset gradients
                       gradParameters:zero()

                       -- f is the average of all criterions
                       local f = 0

                       -- evaluate function for complete mini batch
                       for i = 1,#inputs do
                          -- estimate f
                          local output = model:forward(inputs[i])
                          local err = criterion:forward(output, targets[i])
                          f = f + err

                          -- estimate df/dW
                          local df_do = criterion:backward(output, targets[i])
                          model:backward(inputs[i], df_do)

                       end

                       -- normalize gradients and f(X)
                       gradParameters:div(#inputs)
                       f = f/#inputs

                       -- return f and df/dX
                       return f,gradParameters
                    end

      -- optimize on current mini-batch
      if optimMethod == optim.asgd then
         _,_,average = optimMethod(feval, parameters, optimState)
      else
         optimMethod(feval, parameters, optimState)
      end
   end

   -- time taken
   time = sys.clock() - time
   time = time / trainData:size()[1]
   print("\n==> time to learn 1 sample = " .. (time*1000) .. 'ms')


   -- save/log current net
   local filename = paths.concat(opt.save, 'model.net')
   os.execute('mkdir -p ' .. sys.dirname(filename))
   print('==> saving model to '..filename)
   torch.save(filename, model)

   epoch = epoch + 1
end

function test( model, testData )
   
   -- local vars
   local time = sys.clock()

   -- top score to save corresponding to saved model
   top_score = top_score or 0.1

   -- local vars
   local time = sys.clock()

   -- set model to evaluate mode (for modules that differ in training and testing, like Dropout)
   model:evaluate()

   -- test over test data
   print('==> testing on test set:')
   correct = 0
   for t = 1,testData:size()[1] do
      -- disp progress
      xlua.progress(t, testData:size()[1])

      -- get new sample
      local input = testData.data[t]
      if opt.type == 'double' then input = input:double()
      elseif opt.type == 'cuda' then input = input:cuda() end
      local target = testData.labels[t]

      -- test sample
      local pred = model:forward(input)
      _, guess  = torch.max(pred,1)
      -- print("\n" .. target .. "\n")
       correct = correct + ((guess[1] == target) and 1 or 0)
   end
   score = correct / (1.0 * testData:size()[1])
   -- timing
   time = sys.clock() - time
   time = time / testData:size()[1]
   print("\n==> time to test 1 sample = " .. (time*1000) .. 'ms')
   print("score: " .. score)

   -- update log/plot ... along with accuracy scores for each digit

   -- here we check to see if the current model is the best yet, and if so, save it
   if top_score < score then
      local top_filename = paths.concat(opt.save, 'winning_model.net')
      os.execute('mkdir -p ' .. sys.dirname(top_filename))
      print('==> saving new top model to '..top_filename)
      torch.save(top_filename, model)
   end

end




