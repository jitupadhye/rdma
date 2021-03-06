function sol = timely_pi()
    clc;clear all;close all;

    global C; % bandwidth 
    global Seg; % MSS 
    global MTU; % MTU
    global delta; % the additive increment step
    global T_high; % if RTT is greater than this, decrease rate multiplicatively.
    global T_low; % if RTT is lower than this, do increase rate additively. 
    global prop; % propagation delay. 
    global minRTT; % 20 microseconds, defined protocol parameter
    global beta; % beta, protocol parameter
    global alpha; % alpha, protocol parameter.
    global maxQueue; % max queue. 
    global numFlows;  % number of flows. 
    global initVal; % column of initial values (rate and RTT gradient for each flow, plus initial queue length). 
    global sim_length;
    global a; % PI parameters
    global b; % PI parameters
    global qref;
    global numCalls;

    %
    % Simulation control
    % 
    step_len = 20e-3 ; % 5 microseconds
    sim_length = 500e-2; % 100 milliseconds 
    numCalls = 0; % for debguuing
    
    % 
    % Fixed Parameters
    %
    C = 10 * 1e9; % line rate.
    Seg = 64 * 8 * 1e3; % burstsize.
    MTU = 1 * 8 * 1e3;
    prop = 4e-6; % propagation delay
    
    % Setting PI parameters
    %    a = (5.822e-7);
    %b = (5.8219996e-7);
    b = 1.816e-9/(10*Seg/C);
    a = (1+.0005)*b;
    %b = 0;

    %
    % Parameters we can play with.
    %
    delta = 10e6; % 10Mbps
    T_high = 500e-6; % 500 microseconds (see section 4.4)
    T_low = 50e-6; % 50 microseconds (see section 4.4). 
    minRTT = 20e-6; % 20 microseconds 
    beta = 0.8;
    alpha = 0.875; % unsure
    maxQueue = 20 * C * T_high; % only for corner cases - queue won't grow beyond this. 

    queueLow = C * T_low;
    %queueLow = 0;
    queueHigh = C * T_high;
    qref = (queueHigh+queueLow)/2;
    %
    % Initial conditions: 
    %

    % 1: initial rate of flow 1
    % 2: RTT gradient of flow 1
    % ...
    % 2*NumFlows: RTT graident of flow numFlowss
    % 2*numFlow +1: initial queue size. 
    %

    for numFlows = 10
        initVal = rand(3*numFlows + 1, 1)*0.01;
        initVal(end) = 0;
        for flowId = 1:numFlows
            SetInitialRate(flowId, C*flowId/(numFlows*(numFlows+1)/2));
        end
        
        %
        % Options.
        %
        options = ddeset('MaxStep', step_len, 'RelTol', 1e-2, 'AbsTol', 1e-4);

        %
        % Solve.
        %
        sol = ddesd(@TimelyModel, @DelayModel, initVal, [0, sim_length],options);

        %
        % Extract solution.
        %
        t = sol.x;
        q = sol.y(3*numFlows+1,:);
        p = sol.y(3:3:3*numFlows,:);
        rates = sol.y(1:3:3*numFlows,:);
        [utilization, err] = Utilization(t, rates, q, C);
        
        %
        % Write solution to file.
        % 
        
        fprintf('%d %f %d\n', numFlows, utilization, err);       
        fileName =  sprintf('timely.withpi.%d.%d.dat', numFlows, prop*1e6);
        fileId = fopen (fileName, 'w');
        fprintf(fileId, '## utilization = %f\n', utilization);
        fclose(fileId);
        dlmwrite(fileName,[t',rates'./1e9, q'./8e3], '-append', 'delimiter','\t');
        PlotSol(t, q, rates);
        %break;
    end
end

function dx = TimelyModel(t,x,lag)
    global numFlows;
    global numCalls;
    
    dx  = zeros(3*numFlows+1, 1);
    
    % 1: rate for flow 1
    % 2: rtt gradiant for flow 1
    % 3: p for flow 1
    % 4: rate for flow 2
    % 5: rtt gradiant for flow 2
    % ...
    % 3*numFlows+1: queue
    
    % lag matrix: 
    % (:,1) is t-t' for flow 1
    % (:,2) is t-t'-t* for flow 1
    % (:,3) is t-t' for flow 2
    % (:,4) is t-t'-t* for flow 2
    % ....
     
    rates = x(1:3:3*numFlows);
    dx(end) = QueueDelta(x(end), rates);
    % update rate delta. 
    for j = 0:(numFlows-1)
        i = j*3+1;
        dx(i) = RateDelta(x(i), lag(3*numFlows+1,j*2+1), x(i+1), ...
                          lag(3*numFlows+1,j*2+2), x(i+2));
        %prevprevQueue);
        % prevprevQueue = lag(3*numFlows+1,i);
    end  
    
    % update RTT gradient
    for j = 0:(numFlows-1)
        i = j*3+2;
        dx(i) = RTTGradientDelta(x(i-1), x(i), lag(3*numFlows+1,j*2+1), lag(3*numFlows+1,j*2+2));
    end 
    
    % update p
    for j = 0:(numFlows-1)
        i = j*3+3;
        dx(i) = pDelta(x(i-2), lag(3*numFlows+1,j*2+1), lag(3*numFlows+1,j*2+2));
        % 
    end  

    numCalls = numCalls + 1;
    if (mod(numCalls, 1000) == 0)
        fprintf ('%g %d\n', t, numCalls);
    end
        
end

function deltaP = pDelta(currentRate, prevQueue, prevprevQueue)
    global qref;
    global a;
    global b;
    global C;
   
    %prevQueue
    %prevprevQueue
    %qref
    deltaP = a*(prevQueue - qref) - b*(prevprevQueue - qref);
    %deltaP = deltaP / 1e-5;
    %deltaP = deltaP / RTTSampleInterval(currentRate);
end
       
function deltaQueue = QueueDelta(currentQueue, flowRates)
    global C;
    global maxQueue;
    if (currentQueue > 0)
        if (currentQueue < maxQueue)
            deltaQueue = sum(flowRates)-C;
        else 
            deltaQueue = min(sum(flowRates)-C, 0);
        end
    else
        deltaQueue = max(sum(flowRates)-C, 0);
    end
end

function deltaRate = RateDelta(currentRate, prevQueue, rttGradient, ...
                               prevprevQueue, currentP)
    global delta;
    global beta;
    global C;
    global T_high;
    global T_low;
    global a;
    global b;
    global pold;
    global p;
    global qold;
    %queueLow = C * T_low;
    %queueLow = 0;
    %queueHigh = C * T_high;
    %qref = (T_low+T_high)/2;
    %prevQueue;
    %p = a*(prevQueue - qref) - b*(qold - qref) + pold
    %qold  = prevQueue;

    %  p = min(max(p, 0), 1);
    %pold = p;
    deltaRate = delta - currentP*.5*currentRate;
    
    %   if (prevQueue < queueLow)
        %deltaRate = delta;
        %    deltaRate = -1 * gradient * b* currentRate ...
        %   +1*error*currentRate*a;
        % deltaRate
        %else if (prevQueue > queueHigh)
            % deltaRate = -1 * beta * (1 - queueHigh/prevQueue) *
            % currentRate;
            %        deltaRate = -1 * gradient * b* currentRate ...
            %       +1*error*currentRate*a;
            %else
            %if (rttGradient < 0)
                %deltaRate = delta;
                %   deltaRate = -1 * gradient * b * currentRate ...
                %   +1*error*currentRate*a;
                %deltaRate
                %else
                %deltaRate = -1 * gradient * b* currentRate ...
                %   +1*error*currentRate*a;
                %deltaRate
                %deltaRate = -1 * rttGradient * beta * currentRate;
                %end
                %end
                %end
    
    % do not exceed line rate.
    if (currentRate >= C && deltaRate > 0)
        deltaRate = 0;
    end
    deltaRate = deltaRate / RTTSampleInterval(currentRate);
end

function deltaRTTGradient = RTTGradientDelta(currentRate, currRTTGradient, prevQueue, prevPrevQueue)   
    global alpha;
    global C;
    global minRTT;
    deltaRTTGradient = alpha * (-1 * currRTTGradient + (prevQueue - prevPrevQueue)/(C*minRTT));
    deltaRTTGradient = deltaRTTGradient / RTTSampleInterval(currentRate);
end

function rttSampleInterval = RTTSampleInterval(currentRate)
    global Seg;
    rttSampleInterval = Seg/currentRate;
end

function delays = DelayModel(t, x)
    global Seg;
    global MTU;
    global minRTT;
    global C;
    global prop;
    global numFlows;

    % x is as follows:
    % 1: rate for flow 1
    % 2: rtt gradiant for flow 1
    % 3: rate for flow 2
    % 4: rtt gradiant for flow 2
    % ...
    % 2*numFlows+1: queue

    % delay array is as follows:
    % 1: t - t' for flow 1
    % 2: t - t' - t* for flow 1
    % 3: t - t' for flow 2
    % 4: t - t' - t* for flow 2
    % ...

    delays = zeros(2*numFlows, 1);
    tprime = x(end)/C + MTU/C + prop;
    for j=0:(numFlows-1)
        i = j*3+1;
        tstar = max(Seg/x(i), minRTT);
        delays(2*j+1) = t - tprime;
        delays(2*j+2) = t - tstar - tprime;
    end
end

function [u, err] = Utilization (t, rates, q, C)
    sent = 0;
    tmin = t(1,1);
    tmax = t(1,end);
    max = C * (tmax - tmin);
    err = 0;
    for tindex = 1:(size(t, 2)-1)
        ratesum = 0;
        if (q(tindex) > 1)
            ratesum = C;
        else 
            for flow = 1:size(rates, 1)
                ratesum = ratesum + rates(flow, tindex);
            end
            if (ratesum > C)
                ratesum = C;
                err = err + 1;
            end
        end
        sent = sent + ratesum * (t(1, tindex+1) - t(1, tindex) );
    end
    u = sent/max;
end

function PlotSol(t, q, rates)
    global C;
    global sim_length;
    
    figure
    subplot(2,1,1);
    plot(t,rates'/1e9);
    hold on
    axis([0 sim_length 0 C/1e9])
    xlabel('Time (seconds)')
    ylabel('Throughput (Gbps)')
    
    subplot(2,1,2);
    plot(t,q./(8e3))
    hold on
    axis([0 sim_length 0 max(q)/(8e3)])
    xlabel('Time (seconds)')
    ylabel('Queue (KBytes)')
end

function  SetInitialRate(flownum, rate)
    global initVal;
    initVal(3*(flownum-1)+1, 1) = rate;
end

