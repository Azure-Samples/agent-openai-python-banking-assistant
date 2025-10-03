from typing import Any, AsyncGenerator
from agent_framework import ChatAgent
from agent_framework.exceptions import AgentThreadException
from agent_framework.azure import AzureOpenAIChatClient
from app.agents.azure_chat.account_agent import AccountAgent
from app.agents.azure_chat.transaction_agent import TransactionHistoryAgent
from app.agents.azure_chat.payment_agent import PaymentAgent
from uuid import uuid4
import logging


logger = logging.getLogger(__name__)

class SupervisorAgent :
    """ this agent is used in agent-as-tool orchestration as supervisor agent to decide which tool/agent to use.
    """
    instructions = """
      You are a banking customer support agent triaging customer requests about their banking account, movements, payments.
      You have to evaluate the whole conversation with the customer and forward it to the appropriate agent based on triage rules.
      Once you got a response from an agent use it to provide the answer to the customer.
      
      
      # Triage rules
      - If the user request is related to bank account information like account balance, payment methods, cards and beneficiaries book you should route the request to AccountAgent.
      - If the user request is related to banking movements and payments history, you should route the request to TransactionHistoryAgent.
      - If the user request is related to initiate a payment request, upload a bill or invoice image for payment or manage an on-going payment process, you should route the request to PaymentAgent.
      - If the user request is not related to account, transactions or payments you should respond to the user that you are not able to help with the request.

      
    """
    name = "SupervisorAgent"
    description = "This agent triages customer requests and routes them to the appropriate agent."

    """ A simple in-memory store [thread_id,serialized Thread state] to keep track of threads per user/session. 
    In production, this should be replaced with a persistent store like a database or distributed cache.
    """
    thread_store: dict[str, dict[str, Any]] = {}

    """ like the thread_store but only with supervisor generated messages. it's used for improve accuracy of agent selection avoiding to innclude messages from sub-agents."""
    supervisor_thread_store: dict[str, dict[str, Any]] = {}

    def __init__(self, 
                 azure_chat_client: AzureOpenAIChatClient,
                 account_agent: AccountAgent,
                 transaction_agent: TransactionHistoryAgent,
                 payment_agent: PaymentAgent
                                ):
      self.azure_chat_client = azure_chat_client
      self.account_agent = account_agent
      self.transaction_agent = transaction_agent
      self.payment_agent = payment_agent
     
        

    async def _build_af_agent(self) -> ChatAgent:
      
     
      return self.azure_chat_client.create_agent(
           instructions=SupervisorAgent.instructions,
           name=SupervisorAgent.name,
           tools=[self.route_to_account_agent,self.route_to_transaction_agent,self.route_to_payment_agent])

    async def processMessageStream(self, user_message: str , thread_id : str | None) -> AsyncGenerator[tuple[str, bool, str | None], None]:
      """Process a chat message and stream the response.

      Yields:
          tuple[str, bool, str | None]: (content_chunk, is_final, thread_id)
              - content_chunk: The text chunk to send
              - is_final: Whether this is the final chunk
              - thread_id: The thread ID (only set on final chunk)
      """
      try:
          # Set up agent and thread (same as processMessage)
          agent = await self._build_af_agent()

          processed_thread_id = thread_id
          supervisor_resumed_thread = agent.get_new_thread()

          # Handle thread creation or resumption
          if processed_thread_id is None:
              self.current_thread = agent.get_new_thread()
              processed_thread_id = str(uuid4())
              SupervisorAgent.thread_store[processed_thread_id] = await self.current_thread.serialize()
              SupervisorAgent.supervisor_thread_store[processed_thread_id] = await supervisor_resumed_thread.serialize()
          else:
              serialized_thread = SupervisorAgent.thread_store.get(processed_thread_id, None)
              supervisor_serialized_thread = SupervisorAgent.supervisor_thread_store.get(processed_thread_id, None)
              
              if serialized_thread is None or supervisor_serialized_thread is None:
                  raise AgentThreadException(f"Thread id {processed_thread_id} not found in thread stores")
              
              resumed_thread = agent.get_new_thread()
              await resumed_thread.update_from_thread_state(serialized_thread)
              self.current_thread = resumed_thread
              await supervisor_resumed_thread.update_from_thread_state(supervisor_serialized_thread)

          # Save the original user message
          self.user_message = user_message

          # Stream the response
          full_response = ""

          # Check if agent.run_stream is available
          if not hasattr(agent, 'run_stream'):
              logger.error("Agent does not support streaming. Please disable streaming in the client.")
              error_message = "Streaming is not supported by this agent. Please disable streaming in your settings and try again."
              yield (error_message, True, processed_thread_id)
              return

          try:
              # Use streaming
              async for chunk in agent.run_stream(user_message, thread=supervisor_resumed_thread):
                  if hasattr(chunk, 'text') and chunk.text:
                      content = chunk.text
                      full_response += content
                      # Yield intermediate chunk
                      yield (content, False, None)
          except Exception as stream_error:
              logger.error(f"Error during streaming: {str(stream_error)}", exc_info=True)
              error_message = f"Streaming failed: {str(stream_error)}. Please try again or disable streaming."
              yield (error_message, True, processed_thread_id)
              return

          # Update thread stores
          SupervisorAgent.thread_store[processed_thread_id] = await self.current_thread.serialize()
          SupervisorAgent.supervisor_thread_store[processed_thread_id] = await supervisor_resumed_thread.serialize()

          # Yield final chunk with thread_id
          yield ("", True, processed_thread_id)
          
      except Exception as e:
          logger.error(f"Error in processMessageStream: {str(e)}", exc_info=True)
          # Yield error message as content
          error_message = f"I apologize, but I encountered an error while processing your request: {str(e)}"
          yield (error_message, True, thread_id)

    async def processMessage(self, user_message: str , thread_id : str | None) -> tuple[str, str | None]:
      """Process a chat message using the injected Azure Chat Completion service and return response and thread id."""
      #For azure chat based agents we need to provide the message history externally as there is no built-in memory thread implementation per thread id.
      
      agent = await self._build_af_agent()

      processed_thread_id = thread_id
      supervisor_resumed_thread =  agent.get_new_thread()
      # The AgentThread doesn't allow to provide an external id when using azure openai chat completion agent. so we need to manage the thread id externally.
      if processed_thread_id is None:
         self.current_thread = agent.get_new_thread()
         processed_thread_id = str(uuid4())
         SupervisorAgent.thread_store[processed_thread_id] = await  self.current_thread.serialize()
         SupervisorAgent.supervisor_thread_store[processed_thread_id] = await supervisor_resumed_thread.serialize()

      else :
        serialized_thread = SupervisorAgent.thread_store.get(processed_thread_id, None)
        supervisor_serialized_thread = SupervisorAgent.supervisor_thread_store.get(processed_thread_id, None)
        
        if serialized_thread is None or supervisor_serialized_thread is None:
           raise AgentThreadException(f"Thread id {processed_thread_id} not found in thread stores")
        # set the thread as class instance variable so that it can be shared by agents called in the tools
        
        # there is bug in agent framework. I'll use update_from_thread_state as workaround
        # self.current_thread = await agent.deserialize_thread(serialized_thread)
        resumed_thread =  agent.get_new_thread()
        
        await resumed_thread.update_from_thread_state(serialized_thread)
        self.current_thread = resumed_thread

        
        await supervisor_resumed_thread.update_from_thread_state(supervisor_serialized_thread)

      #save the original user emessage to it can be used by sub-agents. we don't want to use the generated message from supervisor agent as input for sub-agents.
      self.user_message = user_message

      response = await agent.run(user_message, thread=supervisor_resumed_thread)

      #make sure to update the thread store with the latest thread state
      SupervisorAgent.thread_store[processed_thread_id] = await self.current_thread.serialize()
      SupervisorAgent.supervisor_thread_store[processed_thread_id] = await supervisor_resumed_thread.serialize()
      
      return response.text, processed_thread_id

    async def route_to_account_agent(self, user_message: str) -> str:
       """ Route the conversation to Account Agent"""
       af_account_agent = await self.account_agent.build_af_agent()

      #Please note we are using the original user message and not the one generated by the supervisor agent.
       response = await af_account_agent.run(self.user_message, thread=self.current_thread)
       return response.text
    
    async def route_to_transaction_agent(self, user_message: str) -> str:
       """ Route the conversation to Transaction History Agent"""
       af_transaction_agent = await self.transaction_agent.build_af_agent()
      
      #Please note we are using the original user message and not the one generated by the supervisor agent.
       response = await af_transaction_agent.run(self.user_message, thread=self.current_thread)
       return response.text
    
    async def route_to_payment_agent(self, user_message: str) -> str:
       """ Route the conversation to Payment Agent"""
       af_payment_agent = await self.payment_agent.build_af_agent()
      
      #Please note we are using the original user message and not the one generated by the supervisor agent.
       response = await af_payment_agent.run(self.user_message, thread=self.current_thread)
       return response.text